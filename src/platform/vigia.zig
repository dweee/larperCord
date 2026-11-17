//! Vigia de pastas: uma thread que dorme até o sistema avisar que algo mudou numa das
//! pastas e então chama `wake` (os temas e os arquivos de mascote). inotify no Linux,
//! kqueue no macOS, aviso de mudança de pasta no Windows; nada de olhar de tempos em tempos. No
//! navegador não há pasta para vigiar.
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");

/// O que a thread precisa (alocado uma vez por vigia; vive enquanto o app vive).
const Job = struct {
    wake: *const fn () void,
    fd: c_int = -1,
    handles: [8]if (sys.windows) c.HANDLE else usize = undefined,
    n: u32 = 0,
    /// macOS: as pastas (copiadas), para refazer a vigia dos arquivos a cada aviso.
    dirs: [9][:0]const u8 = undefined,
};

/// Vigia `dirs` (arquivo gravado, renomeado para dentro, criado ou apagado) e, se vier,
/// `extra` só para arquivo gravado ou renomeado (a pasta do pywal). Cada rajada de
/// avisos (editores salvam em vários passos) vira uma chamada só de `wake`. Devolve
/// falso se não deu para vigiar nada.
pub fn watch(dirs: []const [:0]const u8, extra: ?[:0]const u8, wake: *const fn () void, name: [*:0]const u8) bool {
    if (sys.web) return false;
    const job = std.heap.c_allocator.create(Job) catch return false;
    job.* = .{ .wake = wake };
    const ok = if (sys.windows) watchWindows(job, dirs, name) else if (sys.macos) watchMacos(job, dirs, extra, name) else watchLinux(job, dirs, extra, name);
    if (!ok) std.heap.c_allocator.destroy(job);
    return ok;
}

/// No Windows: um aviso de mudança por pasta (a maior parte é só uma).
fn watchWindows(job: *Job, dirs: []const [:0]const u8, name: [*:0]const u8) bool {
    const what = c.FILE_NOTIFY_CHANGE_LAST_WRITE | c.FILE_NOTIFY_CHANGE_FILE_NAME;
    for (dirs) |dir| {
        if (job.n == job.handles.len) break;
        const h = c.FindFirstChangeNotificationA(dir.ptr, 0, what);
        if (h == c.INVALID_HANDLE_VALUE) continue;
        job.handles[job.n] = h;
        job.n += 1;
    }
    if (job.n == 0) return false;
    if (c.SDL_CreateThread(runWindows, name, job)) |t| c.SDL_DetachThread(t);
    return true;
}

fn watchLinux(job: *Job, dirs: []const [:0]const u8, extra: ?[:0]const u8, name: [*:0]const u8) bool {
    const fd = c.inotify_init1(c.IN_CLOEXEC);
    if (fd < 0) return false;
    var any = false;
    for (dirs) |dir| {
        if (c.inotify_add_watch(fd, dir.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO | c.IN_CREATE | c.IN_DELETE) >= 0) any = true;
    }
    if (extra) |e| {
        if (c.inotify_add_watch(fd, e.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO) >= 0) any = true;
    }
    if (!any) {
        _ = c.close(fd);
        return false;
    }
    job.fd = fd;
    if (c.SDL_CreateThread(runInotify, name, job)) |t| c.SDL_DetachThread(t);
    return true;
}

/// No macOS: kqueue. O aviso de uma pasta só diz que a lista dela mudou; um arquivo
/// gravado no lugar só avisa por ele mesmo, então cada arquivo das pastas também é
/// vigiado, e a lista é refeita depois de cada aviso (arquivos novos entram).
fn watchMacos(job: *Job, dirs: []const [:0]const u8, extra: ?[:0]const u8, name: [*:0]const u8) bool {
    if (comptime !sys.macos) unreachable;
    const kq = c.kqueue();
    if (kq < 0) return false;
    _ = c.fcntl(kq, c.F_SETFD, @as(c_int, c.FD_CLOEXEC));
    for (dirs) |dir| {
        if (job.n == job.dirs.len) break;
        job.dirs[job.n] = std.heap.c_allocator.dupeSentinel(u8, dir, 0) catch break;
        job.n += 1;
    }
    if (extra) |e| if (job.n < job.dirs.len) {
        if (std.heap.c_allocator.dupeSentinel(u8, e, 0)) |d| {
            job.dirs[job.n] = d;
            job.n += 1;
        } else |_| {}
    };
    job.fd = kq;
    var fds: KqFds = .{};
    defer fds.close();
    if (!armKqueue(job, &fds)) {
        _ = c.close(kq);
        for (job.dirs[0..job.n]) |d| std.heap.c_allocator.free(d);
        return false;
    }
    fds.close();
    if (c.SDL_CreateThread(runKqueue, name, job)) |t| c.SDL_DetachThread(t);
    return true;
}

/// Os arquivos abertos só para vigiar (O_EVTONLY), fechados a cada rodada.
const KqFds = struct {
    fds: [256]c_int = undefined,
    n: usize = 0,

    fn close(k: *KqFds) void {
        for (k.fds[0..k.n]) |fd| _ = c.close(fd);
        k.n = 0;
    }
};

fn kqAdd(kq: c_int, fds: *KqFds, path: [*:0]const u8, flags: c_uint) bool {
    if (fds.n == fds.fds.len) return false;
    const fd = c.open(path, c.O_EVTONLY | c.O_CLOEXEC);
    if (fd < 0) return false;
    var ev = std.mem.zeroes(c.struct_kevent);
    ev.ident = @intCast(fd);
    ev.filter = c.EVFILT_VNODE;
    ev.flags = c.EV_ADD | c.EV_CLEAR;
    ev.fflags = flags;
    if (c.kevent(kq, &ev, 1, null, 0, null) < 0) {
        _ = c.close(fd);
        return false;
    }
    fds.fds[fds.n] = fd;
    fds.n += 1;
    return true;
}

/// Vigia cada pasta e os arquivos dela. Falso se nenhuma pasta abriu.
fn armKqueue(job: *Job, fds: *KqFds) bool {
    const file_flags: c_uint = c.NOTE_WRITE | c.NOTE_EXTEND | c.NOTE_DELETE | c.NOTE_RENAME;
    var any = false;
    for (job.dirs[0..job.n]) |dir| {
        if (!kqAdd(job.fd, fds, dir.ptr, c.NOTE_WRITE | c.NOTE_DELETE | c.NOTE_RENAME)) continue;
        any = true;
        const d = c.opendir(dir.ptr) orelse continue;
        defer _ = c.closedir(d);
        while (c.readdir(d)) |ent| {
            if (ent.*.d_type != c.DT_REG and ent.*.d_type != c.DT_LNK) continue;
            const leaf: [*:0]const u8 = @ptrCast(&ent.*.d_name);
            var pb: [1024]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, std.mem.span(leaf) }, 0) catch continue;
            if (!kqAdd(job.fd, fds, path.ptr, file_flags)) break;
        }
    }
    return any;
}

fn runKqueue(data: ?*anyopaque) callconv(.c) c_int {
    if (comptime !sys.macos) unreachable;
    const job: *Job = @ptrCast(@alignCast(data.?));
    var fds: KqFds = .{};
    while (true) {
        _ = armKqueue(job, &fds);
        var ev: c.struct_kevent = undefined;
        const n = c.kevent(job.fd, null, 0, &ev, 1, null);
        fds.close();
        if (n < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
        if (n <= 0) return 0;
        // Junta rajadas de eventos (editores salvam em vários passos).
        c.SDL_Delay(60);
        job.wake();
    }
}

fn runInotify(data: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(data.?));
    var events: [4096]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
    while (true) {
        const n = c.read(job.fd, &events, events.len);
        if (n <= 0) return 0;
        // Junta rajadas de eventos (editores salvam em vários passos).
        c.SDL_Delay(60);
        job.wake();
    }
}

fn runWindows(data: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(data.?));
    while (true) {
        const r = c.WaitForMultipleObjects(job.n, &job.handles, 0, c.INFINITE);
        if (r >= c.WAIT_OBJECT_0 + job.n) return 0;
        // Junta rajadas de eventos (editores salvam em vários passos).
        c.SDL_Delay(60);
        _ = c.FindNextChangeNotification(job.handles[r - c.WAIT_OBJECT_0]);
        job.wake();
    }
}
