// Ganchos do Inspetor (src/inspect/captura.zig): com IMGUI_ENABLE_TEST_ENGINE, o ImGui
// avisa cada item que entra na tela (área clicável, botão, caixa de texto, janela) com o
// retângulo, o ID, o recorte, as flags e o rótulo. Só chama com `TestEngineHookItems`
// ligado no contexto, o que o Inspetor faz só no contexto da janela principal e só
// enquanto grava: fora disso cada item paga a leitura de um booleano.
#include "imgui.h"
#include "imgui_internal.h"
#include <string.h>

extern "C" {

// Uma linha por item, lida pelo Zig no fim do quadro (larper_insp_items).
struct LarperInspItem {
    unsigned int id;
    unsigned int window;
    void *draw_list;
    float x0, y0, x1, y1;
    float cx0, cy0, cx1, cy1;
    int item_flags;
    int status;
    int scope;
    int label;
    unsigned int order;
    int is_window;
};

// Postos pelo Zig: o pedaço do layout que está desenhando agora e o contador que dá a
// ordem de tudo que entra no quadro (itens daqui e textos, imagens e fundos de lá).
int larper_insp_scope = -1;
unsigned int larper_insp_order = 0;

}

static ImVector<LarperInspItem> g_items;
static ImVector<char> g_labels;
// Um quadro com mais itens que isto é um bug de outro lugar: não cresce sem fim.
static const int max_items = 30000;
static const int max_label_bytes = 1 << 20;

static int keepLabel(const char *label) {
    if (!label || !label[0]) return -1;
    int n = (int)strlen(label);
    if (n > 200) n = 200;
    if (g_labels.Size + n + 1 > max_label_bytes) return -1;
    const int at = g_labels.Size;
    g_labels.resize(at + n + 1);
    memcpy(g_labels.Data + at, label, (size_t)n);
    g_labels.Data[at + n] = 0;
    return at;
}

void ImGuiTestEngineHook_ItemAdd(ImGuiContext *ctx, ImGuiID id, const ImRect &bb, const ImGuiLastItemData *item_data) {
    ImGuiContext &g = *ctx;
    if (g_items.Size >= max_items) return;
    ImGuiWindow *w = g.CurrentWindow;
    LarperInspItem it;
    memset(&it, 0, sizeof(it));
    it.id = id;
    it.window = w ? w->ID : 0;
    it.draw_list = w ? w->DrawList : NULL;
    const ImRect r = item_data ? item_data->Rect : bb;
    it.x0 = r.Min.x;
    it.y0 = r.Min.y;
    it.x1 = r.Max.x;
    it.y1 = r.Max.y;
    const ImRect clip = w ? w->ClipRect : r;
    it.cx0 = clip.Min.x;
    it.cy0 = clip.Min.y;
    it.cx1 = clip.Max.x;
    it.cy1 = clip.Max.y;
    it.item_flags = item_data ? (int)item_data->ItemFlags : 0;
    it.status = item_data ? (int)item_data->StatusFlags : 0;
    it.scope = larper_insp_scope;
    it.order = larper_insp_order++;
    // Sem item_data: é a própria janela (Begin), com o nome dela como rótulo.
    it.is_window = item_data == NULL && w != NULL && w->ID == id;
    it.label = it.is_window ? keepLabel(w->Name) : -1;
    g_items.push_back(it);
}

void ImGuiTestEngineHook_ItemInfo(ImGuiContext *, ImGuiID id, const char *label, ImGuiItemStatusFlags flags) {
    // É quase sempre o último item: procura só entre os mais recentes.
    for (int i = g_items.Size - 1; i >= 0 && i >= g_items.Size - 16; i--) {
        if (g_items[i].id != id) continue;
        g_items[i].status |= (int)flags;
        if (g_items[i].label < 0) g_items[i].label = keepLabel(label);
        return;
    }
}

void ImGuiTestEngineHook_Log(ImGuiContext *, const char *, ...) {}

// A ferramenta de pilha de IDs do ImGui pergunta o rótulo de um ID.
const char *ImGuiTestEngine_FindItemDebugLabel(ImGuiContext *, ImGuiID id) {
    for (int i = g_items.Size - 1; i >= 0; i--)
        if (g_items[i].id == id && g_items[i].label >= 0) return g_labels.Data + g_items[i].label;
    return NULL;
}

extern "C" {

// Liga ou desliga os ganchos no contexto atual (o da janela principal).
void larper_insp_enable(int on) {
    ImGuiContext *g = ImGui::GetCurrentContext();
    if (g) g->TestEngineHookItems = on != 0;
}

void larper_insp_clear(void) {
    g_items.resize(0);
    g_labels.resize(0);
}

int larper_insp_count(void) { return g_items.Size; }

const LarperInspItem *larper_insp_items(void) { return g_items.Data; }

const char *larper_insp_label(int at) { return at >= 0 && at < g_labels.Size ? g_labels.Data + at : ""; }

// O que o ImGui sabe do mouse: a janela embaixo dele e o item ativo/em cima.
unsigned int larper_insp_hovered_window(void) {
    ImGuiContext *g = ImGui::GetCurrentContext();
    return g && g->HoveredWindow ? g->HoveredWindow->ID : 0;
}

unsigned int larper_insp_hovered_id(void) {
    ImGuiContext *g = ImGui::GetCurrentContext();
    return g ? g->HoveredIdPreviousFrame : 0;
}

unsigned int larper_insp_active_id(void) {
    ImGuiContext *g = ImGui::GetCurrentContext();
    return g ? g->ActiveId : 0;
}

// Quantas janelas do ImGui existem e o nome/ID/retângulo de cada uma (para a árvore).
int larper_insp_window_count(void) {
    ImGuiContext *g = ImGui::GetCurrentContext();
    return g ? g->Windows.Size : 0;
}

int larper_insp_window(int i, unsigned int *id, const char **name, float *rect, int *active, void **draw_list) {
    ImGuiContext *g = ImGui::GetCurrentContext();
    if (!g || i < 0 || i >= g->Windows.Size) return 0;
    ImGuiWindow *w = g->Windows[i];
    *id = w->ID;
    *name = w->Name;
    rect[0] = w->Pos.x;
    rect[1] = w->Pos.y;
    rect[2] = w->Pos.x + w->Size.x;
    rect[3] = w->Pos.y + w->Size.y;
    *active = w->WasActive ? 1 : 0;
    *draw_list = w->DrawList;
    return 1;
}

}
