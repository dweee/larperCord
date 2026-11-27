//! Os avisos do Windows com botões: o ToastNotification do WinRT no lugar do balão
//! da bandeja, com "Responder" (e a caixa de texto ao lado), "Marcar como lida" e o
//! clique que abre a conversa. O Activated chega aqui dentro do processo, enquanto o
//! app está aberto (sem servidor COM registrado), numa thread do sistema: ele só põe
//! o pedido numa fila e acorda o laço (Wake.notificacao).
//!
//! Tudo pelo COM na mão, com as tabelas das interfaces escritas aqui (a ordem é a do
//! windows.ui.notifications.idl). O combase.dll é aberto na hora. Um app sem pacote
//! precisa de um AppUserModelID: ele fica no registro do usuário
//! (HKCU\Software\Classes\AppUserModelId\dev.larpercord, sem administrador), e o
//! processo não troca o dele, para a janela continuar agrupada com o atalho do menu
//! Iniciar que o install.ps1 cria. Qualquer passo que falhe deixa `mostrar` dizer não,
//! e quem chama usa o balão de antes: o aviso nunca some.
const std = @import("std");
const c = @import("c");
const n = @import("../core/notificacao.zig");
const platform = @import("window.zig");
const sys = @import("sys.zig");

const gpa = std.heap.c_allocator;

pub const aumid = "dev.larpercord";
const grupo = "larpercord";

const HRESULT = i32;
const HSTRING = ?*opaque {};
const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const Token = extern struct { value: i64 };

fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

/// RPC_E_CHANGED_MODE: a thread já tem o COM (o SDL abre o STA na janela); serve igual.
const rpc_e_changed_mode: HRESULT = @bitCast(@as(u32, 0x80010106));
const ro_init_multithreaded: i32 = 1;

fn guid(comptime s: []const u8) GUID {
    @setEvalBranchQuota(10_000);
    const hex = struct {
        fn n8(t: []const u8) u8 {
            return std.fmt.parseInt(u8, t, 16) catch unreachable;
        }
    };
    return .{
        .a = std.fmt.parseInt(u32, s[0..8], 16) catch unreachable,
        .b = std.fmt.parseInt(u16, s[9..13], 16) catch unreachable,
        .c = std.fmt.parseInt(u16, s[14..18], 16) catch unreachable,
        .d = .{ hex.n8(s[19..21]), hex.n8(s[21..23]), hex.n8(s[24..26]), hex.n8(s[26..28]), hex.n8(s[28..30]), hex.n8(s[30..32]), hex.n8(s[32..34]), hex.n8(s[34..36]) },
    };
}

const iid_unknown = guid("00000000-0000-0000-c000-000000000046");
const iid_agile = guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");
const iid_manager_statics = guid("50ac103f-d235-4598-bbef-98fe4d1a3ad4");
const iid_manager_statics2 = guid("7ab93c52-0e48-4750-ba9d-1a4113981847");
const iid_history = guid("5caddc63-01d3-4c97-986f-0533483fee14");
const iid_toast_factory = guid("04124b20-82c6-4229-b109-fd9ed4662b53");
const iid_toast2 = guid("9dfb9fd1-143a-490e-90bf-b9fba7132de7");
const iid_xml_document = guid("f7f3a506-1e87-42d6-bcfb-b8c809fa5494");
const iid_xml_document_io = guid("6cd0e74e-ee65-4489-9ebf-ca43e87ba637");
const iid_activated_args = guid("e3bf92f3-c197-436f-8265-0625824f8dac");
const iid_activated_args2 = guid("ab7da512-cc61-568e-81be-304ac31038fa");
/// IMap<HSTRING, IInspectable*>: o ValueSet do UserInput.
const iid_map_string_object = guid("1b0d3570-0877-5ec2-8a2c-3b9539506aca");
const iid_property_value = guid("4bd682dd-7554-40e9-9a9b-82654ede7e62");
/// TypedEventHandler<ToastNotification*, IInspectable*> (Activated).
const iid_activated_handler = guid("ab54de2d-97d9-5528-b6ad-105afe156530");
/// TypedEventHandler<ToastNotification*, ToastFailedEventArgs*> (Failed).
const iid_failed_handler = guid("95e3e803-c969-5e3a-9753-ea2ad22a9a33");

fn same(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

// --- As interfaces -------------------------------------------------------------
// Toda interface do WinRT começa com as 6 do IInspectable (IUnknown + 3); o que
// o app não chama fica como `*const anyopaque`, só para manter o lugar.

const InspectableVt = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,
};

const Inspectable = extern struct { vt: *const extern struct { base: InspectableVt } };

/// IToastNotificationManagerStatics
const ManagerStatics = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        CreateToastNotifier: *const anyopaque,
        CreateToastNotifierWithId: *const fn (*ManagerStatics, HSTRING, *?*Notifier) callconv(.winapi) HRESULT,
        GetTemplateContent: *const anyopaque,
    },
};

/// IToastNotificationManagerStatics2
const ManagerStatics2 = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        get_History: *const fn (*ManagerStatics2, *?*History) callconv(.winapi) HRESULT,
    },
};

/// IToastNotificationHistory
const History = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        RemoveGroup: *const anyopaque,
        RemoveGroupWithId: *const anyopaque,
        RemoveGroupedTagWithId: *const fn (*History, HSTRING, HSTRING, HSTRING) callconv(.winapi) HRESULT,
        RemoveGroupedTag: *const anyopaque,
        Remove: *const anyopaque,
        Clear: *const anyopaque,
        ClearWithId: *const fn (*History, HSTRING) callconv(.winapi) HRESULT,
    },
};

/// IToastNotifier
const Notifier = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        Show: *const fn (*Notifier, *Toast) callconv(.winapi) HRESULT,
        Hide: *const fn (*Notifier, *Toast) callconv(.winapi) HRESULT,
        get_Setting: *const fn (*Notifier, *i32) callconv(.winapi) HRESULT,
        AddToSchedule: *const anyopaque,
        RemoveFromSchedule: *const anyopaque,
        GetScheduledToastNotifications: *const anyopaque,
    },
};

/// IToastNotificationFactory
const ToastFactory = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        CreateToastNotification: *const fn (*ToastFactory, *Inspectable, *?*Toast) callconv(.winapi) HRESULT,
    },
};

/// IToastNotification
const Toast = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        get_Content: *const anyopaque,
        put_ExpirationTime: *const anyopaque,
        get_ExpirationTime: *const anyopaque,
        add_Dismissed: *const anyopaque,
        remove_Dismissed: *const anyopaque,
        add_Activated: *const fn (*Toast, *Handler, *Token) callconv(.winapi) HRESULT,
        remove_Activated: *const anyopaque,
        add_Failed: *const fn (*Toast, *Handler, *Token) callconv(.winapi) HRESULT,
        remove_Failed: *const anyopaque,
    },
};

/// IToastNotification2
const Toast2 = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        put_Tag: *const fn (*Toast2, HSTRING) callconv(.winapi) HRESULT,
        get_Tag: *const anyopaque,
        put_Group: *const fn (*Toast2, HSTRING) callconv(.winapi) HRESULT,
        get_Group: *const anyopaque,
        put_SuppressPopup: *const anyopaque,
        get_SuppressPopup: *const anyopaque,
    },
};

/// IXmlDocumentIO
const XmlDocumentIO = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        LoadXml: *const fn (*XmlDocumentIO, HSTRING) callconv(.winapi) HRESULT,
        LoadXmlWithSettings: *const anyopaque,
        SaveToFileAsync: *const anyopaque,
    },
};

/// IToastActivatedEventArgs
const ActivatedArgs = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        get_Arguments: *const fn (*ActivatedArgs, *HSTRING) callconv(.winapi) HRESULT,
    },
};

/// IToastActivatedEventArgs2
const ActivatedArgs2 = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        get_UserInput: *const fn (*ActivatedArgs2, *?*Inspectable) callconv(.winapi) HRESULT,
    },
};

/// IMap<HSTRING, IInspectable*>
const MapStringObject = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        Lookup: *const fn (*MapStringObject, HSTRING, *?*Inspectable) callconv(.winapi) HRESULT,
        get_Size: *const anyopaque,
        HasKey: *const anyopaque,
        GetView: *const anyopaque,
        Insert: *const anyopaque,
        Remove: *const anyopaque,
        Clear: *const anyopaque,
    },
};

/// IPropertyValue (o texto da caixa vem numa caixinha dessas)
const PropertyValue = extern struct {
    vt: *const extern struct {
        base: InspectableVt,
        get_Type: *const anyopaque,
        get_IsNumericScalar: *const anyopaque,
        GetUInt8: *const anyopaque,
        GetInt16: *const anyopaque,
        GetUInt16: *const anyopaque,
        GetInt32: *const anyopaque,
        GetUInt32: *const anyopaque,
        GetInt64: *const anyopaque,
        GetUInt64: *const anyopaque,
        GetSingle: *const anyopaque,
        GetDouble: *const anyopaque,
        GetChar16: *const anyopaque,
        GetBoolean: *const anyopaque,
        GetString: *const fn (*PropertyValue, *HSTRING) callconv(.winapi) HRESULT,
    },
};

fn release(p: anytype) void {
    _ = p.vt.base.Release(@ptrCast(p));
}

fn query(p: anytype, iid: *const GUID, comptime T: type) ?*T {
    var out: ?*anyopaque = null;
    if (!ok(p.vt.base.QueryInterface(@ptrCast(p), iid, &out))) return null;
    return @ptrCast(@alignCast(out orelse return null));
}

// --- O combase.dll ---------------------------------------------------------------

const Ro = struct {
    RoInitialize: *const fn (i32) callconv(.winapi) HRESULT,
    RoGetActivationFactory: *const fn (HSTRING, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    RoActivateInstance: *const fn (HSTRING, *?*Inspectable) callconv(.winapi) HRESULT,
    WindowsCreateString: *const fn ([*]const u16, u32, *HSTRING) callconv(.winapi) HRESULT,
    WindowsDeleteString: *const fn (HSTRING) callconv(.winapi) HRESULT,
    WindowsGetStringRawBuffer: *const fn (HSTRING, ?*u32) callconv(.winapi) ?[*]const u16,
};
var ro: Ro = undefined;

/// UTF-8 para um HSTRING (quem chama solta com `apagar`). Nulo: não deu.
fn hstr(s: []const u8) ?HSTRING {
    const w = std.unicode.utf8ToUtf16LeAlloc(gpa, s) catch return null;
    defer gpa.free(w);
    var h: HSTRING = null;
    if (!ok(ro.WindowsCreateString(w.ptr, @intCast(w.len), &h))) return null;
    return h;
}

fn apagar(h: HSTRING) void {
    if (h != null) _ = ro.WindowsDeleteString(h);
}

/// Um HSTRING em UTF-8 (do gpa). Vazio, ou não deu: "".
fn utf8(h: HSTRING) []u8 {
    var len: u32 = 0;
    const p = ro.WindowsGetStringRawBuffer(h, &len) orelse return &.{};
    return std.unicode.utf16LeToUtf8Alloc(gpa, p[0..len]) catch &.{};
}

fn factory(comptime T: type, classe: []const u8, iid: *const GUID) ?*T {
    const h = hstr(classe) orelse return null;
    defer apagar(h);
    var out: ?*anyopaque = null;
    if (!ok(ro.RoGetActivationFactory(h, iid, &out))) return null;
    return @ptrCast(@alignCast(out orelse return null));
}

// --- O evento -------------------------------------------------------------------

/// O objeto COM que o Activated e o Failed chamam (um TypedEventHandler): só
/// QueryInterface, AddRef, Release e Invoke. Ágil (IAgileObject): o sistema chama
/// de qualquer thread, sem passar pela da janela.
const Handler = extern struct {
    vt: *const HandlerVt,
    refs: u32,
    /// O Failed guarda o aviso, para o balão mostrar o mesmo texto.
    aviso: ?*n.Aviso,
};

const HandlerVt = extern struct {
    QueryInterface: *const fn (*Handler, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*Handler) callconv(.winapi) u32,
    Release: *const fn (*Handler) callconv(.winapi) u32,
    Invoke: *const fn (*Handler, ?*Toast, ?*Inspectable) callconv(.winapi) HRESULT,
};

const e_nointerface: HRESULT = @bitCast(@as(u32, 0x80004002));

fn queryAtivado(h: *Handler, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    return queryCom(h, iid, out, &iid_activated_handler);
}
fn queryFalha(h: *Handler, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    return queryCom(h, iid, out, &iid_failed_handler);
}
fn queryCom(h: *Handler, iid: *const GUID, out: *?*anyopaque, delegado: *const GUID) HRESULT {
    if (same(iid, delegado) or same(iid, &iid_unknown) or same(iid, &iid_agile)) {
        _ = addRef(h);
        out.* = h;
        return 0;
    }
    out.* = null;
    return e_nointerface;
}

fn addRef(h: *Handler) callconv(.winapi) u32 {
    return @atomicRmw(u32, &h.refs, .Add, 1, .acq_rel) + 1;
}

fn releaseCom(h: *Handler) callconv(.winapi) u32 {
    const left = @atomicRmw(u32, &h.refs, .Sub, 1, .acq_rel) - 1;
    if (left == 0) {
        if (h.aviso) |a| {
            gpa.free(a.buf);
            gpa.destroy(a);
        }
        gpa.destroy(h);
    }
    return left;
}

const vt_ativado: HandlerVt = .{ .QueryInterface = &queryAtivado, .AddRef = &addRef, .Release = &releaseCom, .Invoke = &ativado };
const vt_falha: HandlerVt = .{ .QueryInterface = &queryFalha, .AddRef = &addRef, .Release = &releaseCom, .Invoke = &falhou };

/// Clique no aviso ou num botão: os `arguments` dele e o que estava na caixa.
fn ativado(_: *Handler, _: ?*Toast, args: ?*Inspectable) callconv(.winapi) HRESULT {
    const a = args orelse return 0;
    const ev = query(a, &iid_activated_args, ActivatedArgs) orelse return 0;
    defer release(ev);
    var h: HSTRING = null;
    if (!ok(ev.vt.get_Arguments(ev, &h))) return 0;
    const argumentos = utf8(h);
    apagar(h);
    defer gpa.free(argumentos);
    const texto = digitado(a);
    defer gpa.free(texto);
    const p = n.deToast(argumentos, texto) orelse return 0;
    voltar(.{ .pedido = p.copiar(gpa) catch return 0 });
    return 0;
}

/// UserInput["reply"]: o ValueSet é um IMap<HSTRING, IInspectable>, e o texto vem
/// num IPropertyValue. Faltando qualquer parte, "" (e "Responder" abre a caixa do app).
fn digitado(args: *Inspectable) []u8 {
    const ev2 = query(args, &iid_activated_args2, ActivatedArgs2) orelse return &.{};
    defer release(ev2);
    var set: ?*Inspectable = null;
    if (!ok(ev2.vt.get_UserInput(ev2, &set))) return &.{};
    const vs = set orelse return &.{};
    defer release(vs);
    const map = query(vs, &iid_map_string_object, MapStringObject) orelse return &.{};
    defer release(map);
    const k = hstr(n.caixa_id) orelse return &.{};
    defer apagar(k);
    var val: ?*Inspectable = null;
    if (!ok(map.vt.Lookup(map, k, &val))) return &.{};
    const v = val orelse return &.{};
    defer release(v);
    const pv = query(v, &iid_property_value, PropertyValue) orelse return &.{};
    defer release(pv);
    var s: HSTRING = null;
    if (!ok(pv.vt.GetString(pv, &s))) return &.{};
    defer apagar(s);
    return utf8(s);
}

/// O Windows não mostrou o aviso: o balão mostra o mesmo texto, e os próximos já vão
/// por ele.
fn falhou(h: *Handler, _: ?*Toast, _: ?*Inspectable) callconv(.winapi) HRESULT {
    desistiu.store(true, .release);
    const a = h.aviso orelse return 0;
    voltar(.{ .devolvida = a.copiar(gpa) catch return 0 });
    return 0;
}

fn novoHandler(vt: *const HandlerVt, aviso: ?*n.Aviso) ?*Handler {
    const h = gpa.create(Handler) catch return null;
    h.* = .{ .vt = vt, .refs = 1, .aviso = aviso };
    return h;
}

// --- O app ---------------------------------------------------------------------

var tentou = false;
var pronto = false;
var desistiu: std.atomic.Value(bool) = .init(false);
var statics: *ManagerStatics = undefined;
var toasts: *ToastFactory = undefined;
var notifier: *Notifier = undefined;
var history: ?*History = null;
var lock: ?*c.SDL_Mutex = null;
var voltas: std.ArrayList(n.Volta) = .empty;
var wake_type: u32 = 0;
var classico = false;

/// Os avisos ainda na tela ou na central, até `n.max_vivas` (o Activated só chega
/// a quem o app ainda segura).
const Viva = struct { toast: *Toast, tag: u32, alvo: n.Alvo };
var vivas: [n.max_vivas]Viva = undefined;
var n_vivas: usize = 0;
var proxima_tag: u32 = 1;

/// O QA confere por aqui (o Windows de verdade não roda no CI).
pub const medidas = struct {
    pub var mostrados: u32 = 0;
    pub var recusados: u32 = 0;
};

/// O mascote dos avisos (o ícone do AppUserModelID; o Windows pode demorar a trocar).
pub fn mascote(classic: bool) void {
    if (classic == classico) return;
    classico = classic;
    if (pronto) _ = registrar();
}

/// O Windows não aceitou: os avisos saem pelo balão, sem botões.
pub fn recusado() bool {
    return desistiu.load(.acquire) or (tentou and !pronto);
}

/// Mostra o aviso. Falso: não deu, e quem chama usa o balão da bandeja.
pub fn mostrar(wake: u32, a: n.Aviso) bool {
    if (comptime !sys.windows) return false;
    wake_type = wake;
    if (desistiu.load(.acquire)) return false;
    if (!tentou) {
        tentou = true;
        pronto = iniciar();
        if (!pronto) std.log.info("notificações: sem os avisos do WinRT, fica o balão da bandeja", .{});
    }
    if (!pronto) return false;
    // Desligadas pela pessoa ou pela política: nem balão (ela escolheu). Sem o
    // registro valer (DisabledByManifest) ou sem resposta: o balão.
    var setting: i32 = 0;
    if (!ok(notifier.vt.get_Setting(notifier, &setting)) or setting == 4) {
        desistiu.store(true, .release);
        medidas.recusados += 1;
        return false;
    }
    if (setting != 0) return true;
    if (!show(a)) {
        desistiu.store(true, .release);
        medidas.recusados += 1;
        return false;
    }
    medidas.mostrados += 1;
    return true;
}

fn iniciar() bool {
    lock = c.SDL_CreateMutex() orelse return false;
    const lib = c.SDL_LoadObject("combase.dll") orelse return false;
    inline for (@typeInfo(Ro).@"struct".field_names) |fname| {
        const sym = c.SDL_LoadFunction(lib, fname.ptr) orelse return false;
        @field(ro, fname) = @ptrCast(sym);
    }
    const hr = ro.RoInitialize(ro_init_multithreaded);
    if (!ok(hr) and hr != rpc_e_changed_mode) return false;
    if (!registrar()) return false;
    statics = factory(ManagerStatics, "Windows.UI.Notifications.ToastNotificationManager", &iid_manager_statics) orelse return false;
    toasts = factory(ToastFactory, "Windows.UI.Notifications.ToastNotification", &iid_toast_factory) orelse return false;
    const id = hstr(aumid) orelse return false;
    defer apagar(id);
    var nt: ?*Notifier = null;
    if (!ok(statics.vt.CreateToastNotifierWithId(statics, id, &nt))) return false;
    notifier = nt orelse return false;
    // A central de avisos (para tirar de lá os que perderam os botões); sem ela, só sai da tela.
    if (query(statics, &iid_manager_statics2, ManagerStatics2)) |s2| {
        defer release(s2);
        var hi: ?*History = null;
        if (ok(s2.vt.get_History(s2, &hi))) history = hi;
    }
    return true;
}

// O registro do usuário: HKEY e as funções do advapi32 (já ligado no build).
const hkcu: usize = @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))));
const key_set_value: u32 = 0x0002;
const reg_sz: u32 = 1;
const win = struct {
    extern "advapi32" fn RegCreateKeyExW(key: usize, sub: [*:0]const u16, reserved: u32, class: ?[*:0]const u16, options: u32, sam: u32, sec: ?*anyopaque, out: *usize, disp: ?*u32) callconv(.winapi) i32;
    extern "advapi32" fn RegSetValueExW(key: usize, name: [*:0]const u16, reserved: u32, kind: u32, data: [*]const u8, size: u32) callconv(.winapi) i32;
    extern "advapi32" fn RegCloseKey(key: usize) callconv(.winapi) i32;
};

/// O AppUserModelID no registro do usuário: o nome e o ícone que o Windows mostra
/// no aviso e em Configurações → Notificações. O ícone é o PNG do mascote, gravado
/// ao lado do cache.
fn registrar() bool {
    const w = std.unicode.utf8ToUtf16LeStringLiteral;
    var k: usize = 0;
    if (win.RegCreateKeyExW(hkcu, w("Software\\Classes\\AppUserModelId\\" ++ aumid), 0, null, 0, key_set_value, null, &k, null) != 0) return false;
    defer _ = win.RegCloseKey(k);
    if (!valor(k, w("DisplayName"), "larperCord")) return false;
    var pb: [1024]u8 = undefined;
    var cb: [512]u8 = undefined;
    const base = sys.cacheHome(&cb) orelse return true;
    const dir = std.fmt.bufPrintSentinel(&pb, "{s}\\larpercord", .{base}, 0) catch return true;
    _ = c.SDL_CreateDirectory(dir.ptr);
    var fb: [1024]u8 = undefined;
    const png = std.fmt.bufPrintSentinel(&fb, "{s}\\notificacao.png", .{dir}, 0) catch return true;
    const bytes = platform.iconPng(classico, .menu);
    if (c.SDL_SaveFile(png.ptr, bytes.ptr, bytes.len)) _ = valor(k, w("IconUri"), png);
    return true;
}

fn valor(k: usize, nome: [*:0]const u16, s: []const u8) bool {
    const wz = std.unicode.utf8ToUtf16LeAllocZ(gpa, s) catch return false;
    defer gpa.free(wz);
    return win.RegSetValueExW(k, nome, 0, reg_sz, @ptrCast(wz.ptr), @intCast((wz.len + 1) * 2)) == 0;
}

fn show(a: n.Aviso) bool {
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(gpa);
    n.toastXml(gpa, &xml, a) catch return false;
    const hx = hstr(xml.items) orelse return false;
    defer apagar(hx);
    const classe = hstr("Windows.Data.Xml.Dom.XmlDocument") orelse return false;
    defer apagar(classe);
    var inst: ?*Inspectable = null;
    if (!ok(ro.RoActivateInstance(classe, &inst))) return false;
    const doc_insp = inst orelse return false;
    defer release(doc_insp);
    const io = query(doc_insp, &iid_xml_document_io, XmlDocumentIO) orelse return false;
    defer release(io);
    if (!ok(io.vt.LoadXml(io, hx))) return false;
    // A fábrica quer a interface padrão do XmlDocument (IXmlDocument).
    const doc = query(doc_insp, &iid_xml_document, Inspectable) orelse return false;
    defer release(doc);
    var t: ?*Toast = null;
    if (!ok(toasts.vt.CreateToastNotification(toasts, doc, &t))) return false;
    const toast = t orelse return false;
    const tag = proxima_tag;
    proxima_tag +%= 1;
    marcar(toast, tag);
    var tok: Token = undefined;
    if (!ok(toast.vt.add_Activated(toast, &ativo, &tok))) {
        release(toast);
        return false;
    }
    // O Failed leva uma cópia do aviso (o handler a solta quando o Windows o soltar).
    if (a.copiar(gpa)) |copia| {
        if (gpa.create(n.Aviso)) |pa| {
            pa.* = copia;
            if (novoHandler(&vt_falha, pa)) |hf| {
                _ = toast.vt.add_Failed(toast, hf, &tok);
                _ = releaseCom(hf);
            } else {
                gpa.free(copia.buf);
                gpa.destroy(pa);
            }
        } else |_| gpa.free(copia.buf);
    } else |_| {}
    if (!ok(notifier.vt.Show(notifier, toast))) {
        release(toast);
        return false;
    }
    guardar(.{ .toast = toast, .tag = tag, .alvo = a.alvo });
    return true;
}

/// O Activated de todos os avisos: não guarda nada de nenhum (o que fazer vem nos
/// `arguments`), e vive o app inteiro.
var ativo: Handler = .{ .vt = &vt_ativado, .refs = 1, .aviso = null };

/// Tag e grupo: o que a central usa para tirar um aviso dela.
fn marcar(toast: *Toast, tag: u32) void {
    const t2 = query(toast, &iid_toast2, Toast2) orelse return;
    defer release(t2);
    var tb: [16]u8 = undefined;
    const ht = hstr(std.fmt.bufPrint(&tb, "n{d}", .{tag}) catch return) orelse return;
    defer apagar(ht);
    const hg = hstr(grupo) orelse return;
    defer apagar(hg);
    _ = t2.vt.put_Tag(t2, ht);
    _ = t2.vt.put_Group(t2, hg);
}

fn guardar(v: Viva) void {
    if (n_vivas == vivas.len) {
        tirar(vivas[0]);
        std.mem.copyForwards(Viva, vivas[0 .. n_vivas - 1], vivas[1..n_vivas]);
        n_vivas -= 1;
    }
    vivas[n_vivas] = v;
    n_vivas += 1;
}

/// Sai da tela e da central: sem o app segurando, os botões dele não fariam nada.
fn tirar(v: Viva) void {
    _ = notifier.vt.Hide(notifier, v.toast);
    if (history) |h| {
        var tb: [16]u8 = undefined;
        if (hstr(std.fmt.bufPrint(&tb, "n{d}", .{v.tag}) catch "")) |ht| {
            defer apagar(ht);
            if (hstr(grupo)) |hg| {
                defer apagar(hg);
                if (hstr(aumid)) |hi| {
                    defer apagar(hi);
                    _ = h.vt.RemoveGroupedTagWithId(h, ht, hg, hi);
                }
            }
        }
    }
    release(v.toast);
}

/// Os avisos da conversa `canal` (0: todos) saem: ela foi lida, ou a conta saiu.
pub fn fechar(canal: n.Id) void {
    if (comptime !sys.windows) return;
    if (!pronto) return;
    var i: usize = 0;
    while (i < n_vivas) {
        if (canal == 0 or vivas[i].alvo.canal == canal) {
            tirar(vivas[i]);
            std.mem.copyForwards(Viva, vivas[i .. n_vivas - 1], vivas[i + 1 .. n_vivas]);
            n_vivas -= 1;
        } else i += 1;
    }
}

/// O app está saindo: os nossos saem da central também (de uma sessão anterior que
/// caiu, inclusive), que ninguém atenderia os botões deles.
pub fn parar() void {
    if (comptime !sys.windows) return;
    if (!pronto) return;
    fechar(0);
    if (history) |h| if (hstr(aumid)) |hi| {
        defer apagar(hi);
        _ = h.vt.ClearWithId(h, hi);
    };
}

fn voltar(v: n.Volta) void {
    const l = lock orelse return v.liberar(gpa);
    c.SDL_LockMutex(l);
    voltas.append(gpa, v) catch {
        c.SDL_UnlockMutex(l);
        return v.liberar(gpa);
    };
    c.SDL_UnlockMutex(l);
    platform.Window.wake(wake_type, .notificacao);
}

/// O que voltou (cliques, botões, os que o Windows não mostrou) vai para `out`,
/// vazia e do c_allocator. Quem chama solta cada uma (Volta.liberar).
pub fn pegar(out: *std.ArrayList(n.Volta)) void {
    const l = lock orelse return;
    c.SDL_LockMutex(l);
    defer c.SDL_UnlockMutex(l);
    std.mem.swap(std.ArrayList(n.Volta), &voltas, out);
}
