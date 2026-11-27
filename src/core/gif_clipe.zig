//! Clipes dos GIFs favoritos, a parte sem dependências (testada no `zig build test`): o
//! tamanho de cada clipe, quais quadros entram, a qualidade que acerta o tamanho e a conta
//! da pasta (o que sai pelo teto e o que deixou de ser favorito). Quem baixa, decodifica,
//! codifica e grava é ui/gif_clips.zig.
//!
//! A lista da conta (core/gif_favorites.zig) continua mandando: a pasta é só um cache dela,
//! com um WebP animado pequeno de cada GIF, para a aba Favoritos abrir já animando sem
//! esperar a rede.
const std = @import("std");

/// Lado maior do clipe com a interface em 100% (a célula do seletor tem 197×112).
pub const base_side: u16 = 160;
/// Teto do lado (interface em 200%): acima disso o clipe pesa mais sem melhorar a célula.
pub const max_side: u16 = 320;
pub const fps_cap: u32 = 15;
pub const duration_cap_ms: u32 = 6000;
/// O tamanho que a procura da qualidade tenta acertar (e não passar).
pub const size_target: usize = 40 * 1024;
/// Original desse tamanho ou menor (GIF ou WebP) fica como veio: recodificar não ganha nada.
pub const keep_original_max: usize = 64 * 1024;
/// Teto da pasta de clipes de uma conta.
pub const default_cap: u64 = 50 * 1024 * 1024;
/// Mais que isso na lista guardada é arquivo estragado (ou feito para gastar memória).
pub const max_entries: usize = 10_000;

/// O lado maior do clipe para a escala da tela (pixels por ponto, com o zoom da interface).
pub fn sideFor(scale: f32) u16 {
    const s: f32 = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    return @intFromFloat(std.math.clamp(@round(@as(f32, base_side) * s), @as(f32, base_side), @as(f32, max_side)));
}

/// O tamanho do clipe de um GIF sw×sh com lado maior `side`: nunca aumenta, mantém a
/// proporção (a mesma conta da redução das imagens, ui/images.zig `fit`).
pub fn clipSize(sw: usize, sh: usize, side: u16) [2]usize {
    if (sw == 0 or sh == 0) return .{ 0, 0 };
    const fs: f32 = @floatFromInt(side);
    const scale = @min(1.0, @min(fs / @as(f32, @floatFromInt(sw)), fs / @as(f32, @floatFromInt(sh))));
    return .{
        @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(sw)) * scale)))),
        @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(sh)) * scale)))),
    };
}

/// Quais quadros do original entram no clipe: no máximo `fps_cap` por segundo (um quadro
/// só entra se o anterior que entrou começou há pelo menos 1/15 s; o que fica de fora
/// soma o tempo dele ao que entrou) e só os primeiros `duration_cap_ms`.
pub const Selector = struct {
    /// Onde o próximo quadro começa, no tempo do original.
    t: u64 = 0,
    last: u64 = 0,
    kept: u32 = 0,

    pub const Verdict = union(enum) {
        /// Entra, começando nesse ponto (ms).
        keep: u32,
        skip,
        stop,
    };

    /// O próximo quadro do original, de `ms` milissegundos.
    pub fn feed(s: *Selector, ms: u32) Verdict {
        if (s.t >= duration_cap_ms) return .stop;
        const at = s.t;
        s.t += @max(ms, 1);
        if (s.kept > 0 and (at - s.last) * fps_cap < 1000) return .skip;
        s.kept += 1;
        s.last = at;
        return .{ .keep = @intCast(at) };
    }

    /// Onde o clipe acaba (o último quadro dura até aqui).
    pub fn end(s: *const Selector) u32 {
        return @intCast(@min(s.t, duration_cap_ms));
    }
};

pub const first_quality: f32 = 70;
pub const min_quality: f32 = 10;
pub const top_quality: f32 = 90;
pub const max_passes: u8 = 4;

/// A procura da qualidade do WebP: cada passada codifica com `q` e conta os bytes. Fica a
/// maior qualidade que coube em `size_target`; sem nenhuma, a menor tentada (`prefer`).
pub const Search = struct {
    q: f32 = first_quality,
    passes: u8 = 0,
    /// A maior qualidade que coube (0 = nenhuma ainda) e a menor que passou (acima do
    /// teto = nenhuma ainda).
    fit: f32 = 0,
    over: f32 = top_quality + 1,

    /// O tamanho da passada com `q`. true = vale outra passada, e `q` já é a próxima.
    pub fn feed(s: *Search, size: usize) bool {
        s.passes += 1;
        if (size <= size_target) {
            s.fit = @max(s.fit, s.q);
            // Perto o bastante do alvo, ou já no alto: fica.
            if (size * 10 >= size_target * 6 or s.q >= top_quality) return false;
        } else {
            s.over = @min(s.over, s.q);
            if (s.q <= min_quality) return false;
        }
        if (s.passes >= max_passes) return false;
        const next: f32 = if (s.fit == 0) blk: {
            // Nenhuma coube: desce mais quanto mais longe do alvo (o tamanho cai mais ou
            // menos pela metade a cada 30 pontos nessa faixa).
            const ratio = @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(size_target));
            const drop = std.math.clamp(30 * std.math.log2(ratio), 10, 40);
            break :blk @max(min_quality, s.q - drop);
        } else if (s.over > top_quality)
            // Todas couberam e sobra espaço: sobe.
            @min(top_quality, s.q + 15)
        else
            (s.fit + s.over) / 2;
        // Entre uma que coube e uma que passou, quase nada a ganhar.
        if (s.over <= top_quality and s.fit > 0 and s.over - s.fit < 6) return false;
        s.q = next;
        return true;
    }
};

/// Entre o resultado novo (qualidade `q`, coube ou não) e o guardado até agora: fica o
/// novo? A maior qualidade que coube ganha; sem nenhuma que coube, a menor.
pub fn prefer(q: f32, fits: bool, old_q: ?f32, old_fits: bool) bool {
    const oq = old_q orelse return true;
    if (fits) return !old_fits or q > oq;
    return !old_fits and q < oq;
}

pub fn isGif(data: []const u8) bool {
    return data.len > 6 and std.mem.startsWith(u8, data, "GIF8");
}

pub fn isWebp(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
}

/// O original já é pequeno e o app abre como está: vai inteiro, sem recodificar.
pub fn keepOriginal(data: []const u8) bool {
    return data.len > 0 and data.len <= keep_original_max and (isGif(data) or isWebp(data));
}

/// GIF do Tenor que só existe em MP4 (media.tenor.co/videos/…, ou o MP4 de um favorito
/// guardado como vídeo que não deu para trocar pelo WebP): vira clipe pelo FFmpeg, se tiver.
pub fn tenorVideo(url: []const u8) bool {
    const hosts = [_][]const u8{ "https://media.tenor.co/", "https://media.tenor.com/" };
    for (hosts) |h| if (std.mem.startsWith(u8, url, h)) {
        const path = url[0 .. std.mem.indexOfAny(u8, url, "?#") orelse url.len];
        return std.ascii.endsWithIgnoreCase(path, ".mp4") or std.mem.endsWith(u8, path, "/mp4");
    };
    return false;
}

/// O nome do arquivo de um clipe na pasta da conta: o hash do link do favorito.
pub const File = struct {
    buf: [24]u8 = undefined,
    len: u8 = 0,

    pub fn slice(f: *const File) []const u8 {
        return f.buf[0..f.len];
    }

    pub fn of(url: []const u8, ext: []const u8) File {
        var f: File = .{};
        const s = std.fmt.bufPrint(&f.buf, "{x:0>16}{s}", .{ std.hash.Wyhash.hash(0, url), ext }) catch return .{};
        f.len = @intCast(s.len);
        return f;
    }

    /// Só nomes que o app faz: 16 hexadecimais e .webp ou .gif (nada de "../").
    pub fn parse(name: []const u8) ?File {
        if (name.len < 17 or name.len > 21) return null;
        for (name[0..16]) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return null;
        const ext = name[16..];
        if (!std.mem.eql(u8, ext, ".webp") and !std.mem.eql(u8, ext, ".gif")) return null;
        var f: File = .{ .len = @intCast(name.len) };
        @memcpy(f.buf[0..name.len], name);
        return f;
    }

    pub fn eql(a: *const File, b: *const File) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }
};

pub const Entry = struct {
    url: []u8,
    src: []u8,
    /// Vazio = sem clipe ainda (ou saiu pelo teto).
    file: File = .{},
    size: u64 = 0,
    /// Última vez que o seletor mostrou o clipe (ms desde 1970).
    used: i64 = 0,
    /// Saiu pelo teto: não volta sozinho, só quando o seletor mostrar o GIF de novo.
    evicted: bool = false,

    pub fn hasClip(e: *const Entry) bool {
        return e.file.len > 0;
    }

    fn free(e: Entry, gpa: std.mem.Allocator) void {
        gpa.free(e.url);
        gpa.free(e.src);
    }
};

/// A lista dos favoritos como a pasta conhece (do mais novo para o mais velho, a ordem da
/// conta da última vez) e o clipe de cada um. Só a thread da interface mexe.
pub const Index = struct {
    items: std.ArrayList(Entry) = .empty,
    /// Bytes dos clipes listados.
    total: u64 = 0,

    pub fn deinit(ix: *Index, gpa: std.mem.Allocator) void {
        for (ix.items.items) |e| e.free(gpa);
        ix.items.deinit(gpa);
        ix.* = .{};
    }

    pub fn find(ix: *const Index, url: []const u8) ?usize {
        for (ix.items.items, 0..) |e, i| if (std.mem.eql(u8, e.url, url)) return i;
        return null;
    }

    pub fn clips(ix: *const Index) usize {
        var n: usize = 0;
        for (ix.items.items) |*e| n += @intFromBool(e.hasClip());
        return n;
    }

    /// Link que não cabe numa linha do arquivo (tab, quebra) nem vale guardar.
    fn storable(s: []const u8) bool {
        return s.len > 0 and s.len <= 4096 and std.mem.indexOfAny(u8, s, "\t\r\n") == null;
    }

    /// A lista da conta chegou (`favs`: cada um com `url` e `src`, do mais novo para o mais
    /// velho). Quem não está mais nela sai, e o arquivo do clipe vai em `gone` para apagar;
    /// quem chegou entra sem clipe; a ordem passa a ser a da conta.
    pub fn sync(ix: *Index, gpa: std.mem.Allocator, favs: anytype, gone: *std.ArrayList(File)) !void {
        // Primeiro tudo o que pode faltar memória (a lista fica como estava se faltar);
        // depois a troca, que não falha.
        const Plan = struct {
            /// De onde vem a entrada na lista atual (null = nova, com `url` e `src` nossos).
            from: ?usize,
            url: []u8 = &.{},
            /// Mídia nova (nossa) de uma entrada que já existia; vazio = a mesma.
            src: []u8 = &.{},
        };
        var plan: std.ArrayList(Plan) = .empty;
        defer plan.deinit(gpa);
        errdefer for (plan.items) |p| {
            if (p.from == null) gpa.free(p.url);
            if (p.src.len > 0) gpa.free(p.src);
        };
        try plan.ensureTotalCapacity(gpa, favs.len);
        const taken = try gpa.alloc(bool, ix.items.items.len);
        defer gpa.free(taken);
        @memset(taken, false);
        for (favs) |f| {
            if (!storable(f.url) or !storable(f.src)) continue;
            var dup = false;
            for (plan.items) |p| {
                const u = if (p.from) |i| ix.items.items[i].url else p.url;
                if (std.mem.eql(u8, u, f.url)) dup = true;
            }
            if (dup) continue;
            if (ix.find(f.url)) |i| {
                taken[i] = true;
                // A mídia mudou (outro aparelho guardou outra versão): o clipe era da antiga.
                const src: []u8 = if (std.mem.eql(u8, ix.items.items[i].src, f.src)) &.{} else try gpa.dupe(u8, f.src);
                plan.appendAssumeCapacity(.{ .from = i, .src = src });
                continue;
            }
            const url = try gpa.dupe(u8, f.url);
            const src = gpa.dupe(u8, f.src) catch |err| {
                gpa.free(url);
                return err;
            };
            plan.appendAssumeCapacity(.{ .from = null, .url = url, .src = src });
        }
        var next: std.ArrayList(Entry) = .empty;
        try next.ensureTotalCapacity(gpa, plan.items.len);
        // Daqui em diante nada falha (o que não couber em `gone` sai na faxina da pasta).
        for (plan.items) |p| {
            const i = p.from orelse {
                next.appendAssumeCapacity(.{ .url = p.url, .src = p.src });
                continue;
            };
            var e = ix.items.items[i];
            if (p.src.len > 0) {
                gpa.free(e.src);
                e.src = p.src;
                if (e.hasClip()) gone.append(gpa, e.file) catch {};
                e.file = .{};
                e.size = 0;
                e.evicted = false;
            }
            next.appendAssumeCapacity(e);
        }
        plan.clearRetainingCapacity();
        // O que ficou de fora: não é mais favorito.
        for (ix.items.items, taken) |e, t| {
            if (t) continue;
            if (e.hasClip()) gone.append(gpa, e.file) catch {};
            e.free(gpa);
        }
        ix.items.deinit(gpa);
        ix.items = next;
        ix.recount();
    }

    fn recount(ix: *Index) void {
        ix.total = 0;
        for (ix.items.items) |*e| {
            if (e.hasClip()) ix.total += e.size;
        }
    }

    /// Um clipe pronto para `url` (que entra na frente se a lista ainda não o tinha). O
    /// nome antigo, se era outro, volta para apagar.
    pub fn setClip(ix: *Index, gpa: std.mem.Allocator, url: []const u8, src: []const u8, file: File, size: u64, now: i64) !?File {
        if (!storable(url) or !storable(src)) return error.NotStorable;
        const i = ix.find(url) orelse blk: {
            const u = try gpa.dupe(u8, url);
            const s = gpa.dupe(u8, src) catch |err| {
                gpa.free(u);
                return err;
            };
            ix.items.insert(gpa, 0, .{ .url = u, .src = s }) catch |err| {
                gpa.free(u);
                gpa.free(s);
                return err;
            };
            break :blk 0;
        };
        const e = &ix.items.items[i];
        var old: ?File = null;
        if (e.hasClip()) {
            ix.total -|= e.size;
            if (!e.file.eql(&file)) old = e.file;
        }
        e.file = file;
        e.size = size;
        e.used = now;
        e.evicted = false;
        ix.total += size;
        return old;
    }

    /// O seletor mostrou o clipe de `i` agora.
    pub fn touch(ix: *Index, i: usize, now: i64) void {
        ix.items.items[i].used = now;
    }

    /// Tira o clipe de `i` (o arquivo, para apagar, volta). A entrada continua: é favorito.
    pub fn dropClip(ix: *Index, i: usize, evicted: bool) File {
        const e = &ix.items.items[i];
        const f = e.file;
        if (e.hasClip()) ix.total -|= e.size;
        e.file = .{};
        e.size = 0;
        e.evicted = evicted;
        return f;
    }

    /// O próximo a sair pelo teto: o clipe mostrado há mais tempo (no empate, o favorito
    /// mais velho), nunca `keep`. null = cabe (ou só sobrou `keep`).
    pub fn victim(ix: *const Index, cap: u64, keep: ?usize) ?usize {
        if (ix.total <= cap) return null;
        var best: ?usize = null;
        for (ix.items.items, 0..) |*e, i| {
            if (!e.hasClip() or i == keep) continue;
            if (best == null or e.used <= ix.items.items[best.?].used) best = i;
        }
        return best;
    }

    const header = "larpercord gif-clips 1\n";

    /// Uma linha por favorito, na ordem: arquivo (ou -), tamanho, quando foi usado, se saiu
    /// pelo teto, o link e a mídia, separados por tab.
    pub fn write(ix: *const Index, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(gpa, header);
        for (ix.items.items) |*e| {
            const name = if (e.hasClip()) e.file.slice() else "-";
            try out.print(gpa, "{s}\t{d}\t{d}\t{d}\t{s}\t{s}\n", .{ name, if (e.hasClip()) e.size else 0, e.used, @intFromBool(e.evicted), e.url, e.src });
        }
    }

    /// O arquivo gravado por `write`. Linha estragada fica de fora; cabeçalho errado, nada.
    pub fn read(gpa: std.mem.Allocator, data: []const u8) !Index {
        var ix: Index = .{};
        errdefer ix.deinit(gpa);
        if (!std.mem.startsWith(u8, data, header)) return ix;
        var lines = std.mem.splitScalar(u8, data[header.len..], '\n');
        while (lines.next()) |line| {
            if (ix.items.items.len >= max_entries) break;
            var f = std.mem.splitScalar(u8, line, '\t');
            const name = f.next() orelse continue;
            const size = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
            const used = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue;
            const ev = f.next() orelse continue;
            const url = f.next() orelse continue;
            const src = f.next() orelse continue;
            if (f.next() != null or !storable(url) or !storable(src)) continue;
            if (!std.mem.eql(u8, ev, "0") and !std.mem.eql(u8, ev, "1")) continue;
            const file: File = if (std.mem.eql(u8, name, "-")) .{} else File.parse(name) orelse continue;
            if (ix.find(url) != null) continue;
            const u = try gpa.dupe(u8, url);
            const s = gpa.dupe(u8, src) catch |err| {
                gpa.free(u);
                return err;
            };
            ix.items.append(gpa, .{ .url = u, .src = s, .file = file, .size = if (file.len > 0) size else 0, .used = used, .evicted = ev[0] == '1' }) catch |err| {
                gpa.free(u);
                gpa.free(s);
                return err;
            };
        }
        ix.recount();
        return ix;
    }
};

// --- Testes -----------------------------------------------------------------------

test "lado do clipe segue a escala da tela, com piso e teto" {
    try std.testing.expectEqual(160, sideFor(1));
    try std.testing.expectEqual(240, sideFor(1.5));
    try std.testing.expectEqual(320, sideFor(2));
    try std.testing.expectEqual(320, sideFor(3));
    // Zoom menor que 100% não deixa o clipe pior que o de 100%.
    try std.testing.expectEqual(160, sideFor(0.75));
    try std.testing.expectEqual(160, sideFor(0));
    try std.testing.expectEqual(160, sideFor(std.math.nan(f32)));
}

test "tamanho do clipe: lado maior no limite, proporção mantida, nunca aumenta" {
    try std.testing.expectEqual([2]usize{ 160, 90 }, clipSize(480, 270, 160));
    try std.testing.expectEqual([2]usize{ 48, 160 }, clipSize(90, 300, 160));
    try std.testing.expectEqual([2]usize{ 160, 160 }, clipSize(498, 498, 160));
    try std.testing.expectEqual([2]usize{ 100, 60 }, clipSize(100, 60, 160));
    try std.testing.expectEqual([2]usize{ 320, 1 }, clipSize(4000, 2, 320));
    try std.testing.expectEqual([2]usize{ 0, 0 }, clipSize(0, 10, 160));
}

test "quadros: no máximo 15 por segundo, o tempo do que sai fica no anterior" {
    // O GIF da demonstração: 24 quadros de 50 ms. Entra um sim, um não: 12 de 100 ms.
    var s: Selector = .{};
    var kept: std.ArrayList(u32) = .empty;
    defer kept.deinit(std.testing.allocator);
    for (0..24) |_| switch (s.feed(50)) {
        .keep => |at| try kept.append(std.testing.allocator, at),
        .skip => {},
        .stop => break,
    };
    try std.testing.expectEqual(12, kept.items.len);
    for (kept.items, 0..) |at, i| try std.testing.expectEqual(i * 100, at);
    try std.testing.expectEqual(1200, s.end());
    // 100 ms por quadro já está abaixo do teto: todos entram.
    var slow: Selector = .{};
    for (0..10) |_| try std.testing.expect(slow.feed(100) == .keep);
    // 20 ms (50 qps): um a cada 4 (80 ms), 12,5 por segundo.
    var fast: Selector = .{};
    var n: usize = 0;
    for (0..50) |_| n += @intFromBool(fast.feed(20) == .keep);
    try std.testing.expectEqual(13, n);
    try std.testing.expectEqual(1000, fast.end());
}

test "quadros: só os primeiros 6 s, e o último não passa deles" {
    var s: Selector = .{};
    var kept: usize = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) switch (s.feed(100)) {
        .keep => kept += 1,
        .skip => {},
        .stop => break,
    };
    try std.testing.expectEqual(60, kept);
    try std.testing.expectEqual(duration_cap_ms, s.end());
    // Nunca mais de 90 quadros (15 × 6), nem com quadros curtíssimos.
    var t: Selector = .{};
    kept = 0;
    i = 0;
    while (i < 100_000) : (i += 1) switch (t.feed(1)) {
        .keep => kept += 1,
        .skip => {},
        .stop => break,
    };
    try std.testing.expectEqual(90, kept);
    // Um quadro só, de 10 s: entra, e o clipe acaba nos 6 s.
    var one: Selector = .{};
    try std.testing.expect(one.feed(10_000) == .keep);
    try std.testing.expect(one.feed(100) == .stop);
    try std.testing.expectEqual(duration_cap_ms, one.end());
}

/// A procura com um "codificador" de mentira: bytes = k × q.
fn searchWith(k: f32) struct { q: f32, size: usize, passes: u8 } {
    var s: Search = .{};
    var best_q: ?f32 = null;
    var best_fits = false;
    var best_size: usize = 0;
    while (true) {
        const size: usize = @intFromFloat(k * s.q);
        const fits = size <= size_target;
        if (prefer(s.q, fits, best_q, best_fits)) {
            best_q = s.q;
            best_fits = fits;
            best_size = size;
        }
        if (!s.feed(size)) break;
    }
    return .{ .q = best_q.?, .size = best_size, .passes = s.passes };
}

test "qualidade: acerta perto de 40 KB sem passar, em poucas passadas" {
    // Típico: na primeira passada passa do alvo, a segunda já cabe.
    const typical = searchWith(1000);
    try std.testing.expect(typical.size <= size_target and typical.size * 10 >= size_target * 6);
    try std.testing.expect(typical.passes <= max_passes);
    // Pequeno: sobe a qualidade enquanto couber.
    const small = searchWith(200);
    try std.testing.expect(small.q > first_quality and small.size <= size_target);
    // Pesado demais: desce até o piso e fica a menor tentada.
    const heavy = searchWith(50_000);
    try std.testing.expect(heavy.size > size_target);
    try std.testing.expect(heavy.passes <= max_passes);
    try std.testing.expect(heavy.q < first_quality);
    // Cabe logo de cara, perto do alvo: uma passada só.
    const ok = searchWith(500);
    try std.testing.expectEqual(1, ok.passes);
    try std.testing.expectEqual(first_quality, ok.q);
}

test "qual resultado fica: a maior qualidade que coube, ou a menor que passou" {
    try std.testing.expect(prefer(70, false, null, false));
    try std.testing.expect(prefer(50, true, 70, false));
    try std.testing.expect(!prefer(40, false, 50, true));
    try std.testing.expect(prefer(60, true, 50, true));
    try std.testing.expect(!prefer(45, true, 50, true));
    try std.testing.expect(prefer(30, false, 50, false));
    try std.testing.expect(!prefer(60, false, 50, false));
}

test "original pequeno fica como veio; o resto e o que não abre, não" {
    const gif = "GIF89a" ++ @as([20]u8, @splat(0));
    const webp = "RIFF\x10\x00\x00\x00WEBPVP8X" ++ @as([10]u8, @splat(0));
    try std.testing.expect(keepOriginal(gif));
    try std.testing.expect(keepOriginal(webp));
    try std.testing.expect(!keepOriginal("\x00\x00\x00\x18ftypmp42"));
    try std.testing.expect(!keepOriginal(""));
    var big: [keep_original_max + 1]u8 = @splat(0);
    @memcpy(big[0..6], "GIF89a");
    try std.testing.expect(!keepOriginal(&big));
    try std.testing.expect(keepOriginal(big[0..keep_original_max]));
}

test "mp4 do tenor vira clipe pelo FFmpeg; o resto não" {
    try std.testing.expect(tenorVideo("https://media.tenor.co/videos/ab12/mp4"));
    try std.testing.expect(tenorVideo("https://media.tenor.com/XhYqu5fu4LgAAAPo/cat.mp4?x=1"));
    try std.testing.expect(!tenorVideo("https://media.tenor.com/XhYqu5fu4LgAAAAx/cat.webp"));
    try std.testing.expect(!tenorVideo("https://evil.com/media.tenor.com/a.mp4"));
    try std.testing.expect(!tenorVideo("https://cdn.discordapp.com/attachments/1/2/a.mp4"));
}

test "nome do arquivo: hash do link, e só nomes que o app faz são lidos" {
    const a = File.of("https://tenor.com/view/a", ".webp");
    try std.testing.expectEqual(21, a.len);
    try std.testing.expect(std.mem.endsWith(u8, a.slice(), ".webp"));
    try std.testing.expect(File.parse(a.slice()) != null);
    try std.testing.expect(!a.eql(&File.of("https://tenor.com/view/b", ".webp")));
    try std.testing.expect(File.parse("0123456789abcdef.gif") != null);
    try std.testing.expect(File.parse("../../../etc/passwd") == null);
    try std.testing.expect(File.parse("0123456789ABCDEF.gif") == null);
    try std.testing.expect(File.parse("0123456789abcdef.png") == null);
    try std.testing.expect(File.parse("index") == null);
}

const T = struct { url: []const u8, src: []const u8 };

test "conta da pasta: teto pelo menos usado, sem tirar o que acabou de entrar" {
    const gpa = std.testing.allocator;
    var ix: Index = .{};
    defer ix.deinit(gpa);
    var gone: std.ArrayList(File) = .empty;
    defer gone.deinit(gpa);
    try ix.sync(gpa, &[_]T{ .{ .url = "a", .src = "sa" }, .{ .url = "b", .src = "sb" }, .{ .url = "c", .src = "sc" } }, &gone);
    try std.testing.expectEqual(3, ix.items.items.len);
    try std.testing.expectEqual(0, ix.clips());
    _ = try ix.setClip(gpa, "a", "sa", File.of("a", ".webp"), 30, 100);
    _ = try ix.setClip(gpa, "b", "sb", File.of("b", ".webp"), 30, 200);
    _ = try ix.setClip(gpa, "c", "sc", File.of("c", ".gif"), 30, 300);
    try std.testing.expectEqual(90, ix.total);
    try std.testing.expectEqual(null, ix.victim(90, null));
    // "a" foi mostrado agora: o menos usado passa a ser "b".
    ix.touch(ix.find("a").?, 400);
    try std.testing.expectEqual(ix.find("b").?, ix.victim(70, null).?);
    const f = ix.dropClip(ix.find("b").?, true);
    try std.testing.expect(f.eql(&File.of("b", ".webp")));
    try std.testing.expectEqual(60, ix.total);
    try std.testing.expect(ix.items.items[ix.find("b").?].evicted);
    // Teto menor que tudo: sai o resto, nunca o que acabou de entrar.
    const keep = ix.find("c").?;
    try std.testing.expectEqual(ix.find("a").?, ix.victim(10, keep).?);
    _ = ix.dropClip(ix.find("a").?, true);
    try std.testing.expectEqual(null, ix.victim(10, keep));
    try std.testing.expectEqual(30, ix.total);
    // Clipe refeito com outro formato: o nome antigo volta para apagar.
    const old = (try ix.setClip(gpa, "c", "sc", File.of("c", ".webp"), 20, 500)).?;
    try std.testing.expect(old.eql(&File.of("c", ".gif")));
    try std.testing.expectEqual(20, ix.total);
    // GIF novo (estrela antes da lista chegar): entra na frente.
    _ = try ix.setClip(gpa, "d", "sd", File.of("d", ".webp"), 5, 600);
    try std.testing.expectEqualStrings("d", ix.items.items[0].url);
    try std.testing.expectEqual(25, ix.total);
}

test "lista da conta: quem saiu dos favoritos leva o clipe junto; mídia trocada refaz" {
    const gpa = std.testing.allocator;
    var ix: Index = .{};
    defer ix.deinit(gpa);
    var gone: std.ArrayList(File) = .empty;
    defer gone.deinit(gpa);
    try ix.sync(gpa, &[_]T{ .{ .url = "a", .src = "sa" }, .{ .url = "b", .src = "sb" }, .{ .url = "c", .src = "sc" } }, &gone);
    _ = try ix.setClip(gpa, "a", "sa", File.of("a", ".webp"), 10, 1);
    _ = try ix.setClip(gpa, "b", "sb", File.of("b", ".webp"), 20, 2);
    _ = try ix.setClip(gpa, "c", "sc", File.of("c", ".webp"), 40, 3);
    // Outro aparelho tirou "b", pôs "x" na frente e trocou a mídia de "c"; um link com
    // tab (não cabe no arquivo) e um repetido ficam de fora.
    try ix.sync(gpa, &[_]T{ .{ .url = "x", .src = "sx" }, .{ .url = "a", .src = "sa" }, .{ .url = "c", .src = "sc2" }, .{ .url = "a\tz", .src = "s" }, .{ .url = "a", .src = "sa" } }, &gone);
    try std.testing.expectEqual(3, ix.items.items.len);
    try std.testing.expectEqualStrings("x", ix.items.items[0].url);
    try std.testing.expectEqualStrings("a", ix.items.items[1].url);
    try std.testing.expectEqualStrings("c", ix.items.items[2].url);
    try std.testing.expect(!ix.items.items[0].hasClip());
    try std.testing.expect(ix.items.items[1].hasClip());
    try std.testing.expect(!ix.items.items[2].hasClip());
    try std.testing.expectEqualStrings("sc2", ix.items.items[2].src);
    try std.testing.expectEqual(2, gone.items.len);
    try std.testing.expect(gone.items[0].eql(&File.of("c", ".webp")));
    try std.testing.expect(gone.items[1].eql(&File.of("b", ".webp")));
    try std.testing.expectEqual(10, ix.total);
    // Lista vazia: tudo sai.
    gone.clearRetainingCapacity();
    try ix.sync(gpa, &[_]T{}, &gone);
    try std.testing.expectEqual(0, ix.items.items.len);
    try std.testing.expectEqual(1, gone.items.len);
    try std.testing.expectEqual(0, ix.total);
}

test "arquivo da lista: ida e volta, e linha estragada fica de fora" {
    const gpa = std.testing.allocator;
    var ix: Index = .{};
    defer ix.deinit(gpa);
    var gone: std.ArrayList(File) = .empty;
    defer gone.deinit(gpa);
    try ix.sync(gpa, &[_]T{ .{ .url = "https://tenor.com/view/a", .src = "https://media.tenor.com/aAAAAx/a.webp" }, .{ .url = "https://tenor.com/view/b", .src = "demo:gif" } }, &gone);
    _ = try ix.setClip(gpa, "https://tenor.com/view/a", "https://media.tenor.com/aAAAAx/a.webp", File.of("https://tenor.com/view/a", ".webp"), 41234, 1700000000123);
    ix.items.items[1].evicted = true;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try ix.write(gpa, &out);
    var back = try Index.read(gpa, out.items);
    defer back.deinit(gpa);
    try std.testing.expectEqual(2, back.items.items.len);
    try std.testing.expectEqual(41234, back.total);
    try std.testing.expectEqualStrings(ix.items.items[0].file.slice(), back.items.items[0].file.slice());
    try std.testing.expectEqual(1700000000123, back.items.items[0].used);
    try std.testing.expect(back.items.items[1].evicted and !back.items.items[1].hasClip());
    try std.testing.expectEqualStrings("demo:gif", back.items.items[1].src);
    // Linhas estragadas: nome que o app não faz, número torto, campos a mais ou a menos.
    const bad = Index.header ++
        "../x.webp\t1\t1\t0\tu1\ts\n" ++
        "0123456789abcdef.webp\tx\t1\t0\tu2\ts\n" ++
        "0123456789abcdef.webp\t1\t1\t0\tu3\n" ++
        "0123456789abcdef.webp\t1\t1\t0\tu4\ts\textra\n" ++
        "0123456789abcdef.webp\t1\t1\t2\tu5\ts\n" ++
        "0123456789abcdef.webp\t7\t1\t0\tu6\ts\n";
    var b2 = try Index.read(gpa, bad);
    defer b2.deinit(gpa);
    try std.testing.expectEqual(1, b2.items.items.len);
    try std.testing.expectEqualStrings("u6", b2.items.items[0].url);
    try std.testing.expectEqual(7, b2.total);
    // Cabeçalho de outro formato: nada.
    var b3 = try Index.read(gpa, "outra coisa\n-\t0\t0\t0\tu\ts\n");
    defer b3.deinit(gpa);
    try std.testing.expectEqual(0, b3.items.items.len);
}

test "sem vazamento quando falta memória na lista" {
    const run = struct {
        fn f(gpa: std.mem.Allocator) !void {
            var ix: Index = .{};
            defer ix.deinit(gpa);
            var gone: std.ArrayList(File) = .empty;
            defer gone.deinit(gpa);
            try ix.sync(gpa, &[_]T{ .{ .url = "a", .src = "sa" }, .{ .url = "b", .src = "sb" } }, &gone);
            _ = try ix.setClip(gpa, "a", "sa", File.of("a", ".webp"), 10, 1);
            _ = try ix.setClip(gpa, "n", "sn", File.of("n", ".webp"), 10, 2);
            try ix.sync(gpa, &[_]T{ .{ .url = "b", .src = "sb2" }, .{ .url = "z", .src = "sz" } }, &gone);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            try ix.write(gpa, &out);
            var back = try Index.read(gpa, out.items);
            back.deinit(gpa);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, run.f, .{});
}
