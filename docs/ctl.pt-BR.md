# Controlando o larperCord de fora (`larpercord ctl`)

O `larpercord ctl` fala com o larperCord que já está aberto: mutar e ensurdecer, aperte para
falar, mostrar ou esconder a janela, abrir um canal, ler as contas de não lidas ou acompanhar
elas ao vivo. É para scripts, barras de status e atalhos do sistema. O caso mais útil é o
**aperte para falar global no Linux**: lá o SDL não tem atalho global, mas o seu compositor tem,
e ele pode chamar `larpercord ctl ptt-down` quando você aperta uma tecla e `larpercord ctl
ptt-up` quando solta.

Funciona no Linux e no Windows, com a janela aberta, minimizada ou escondida na bandeja.

## Ligando e desligando

Configurações → Avançado → **Controle externo (larpercord ctl)**. Vem ligado. Desligado, o app
não escuta nada: não há porta nem thread esperando ninguém.

Ninguém mais consegue usar: o app escuta só em `127.0.0.1`, numa porta sorteada, e toda conexão
tem que começar com uma chave sorteada, nova a cada vez que o app abre. A porta e a chave ficam
num arquivo que só o seu usuário lê (`~/.config/larpercord/ctl.port` no Linux,
`%APPDATA%\larpercord\ctl.port` no Windows). Os outros usuários do mesmo computador não leem, e
outros computadores não alcançam a porta.

Nada roda enquanto ninguém usa: uma thread espera uma conexão, parada, e o comando é atendido no
meio dos eventos do app, sem desenhar nada.

## Comandos

| Comando | O que faz |
| --- | --- |
| `status` | Conexão, conta, call e não lidas, em JSON (abaixo) |
| `unread` | As contas de não lidas, em JSON: `{"mentions":3,"dms":1,"channels":5}` |
| `mute` / `unmute` / `toggle-mute` | Como o botão do microfone e `Ctrl+Shift+M` (o som, o que vai para o Discord, guardado para a próxima vez) |
| `deafen` / `undeafen` / `toggle-deafen` | Como o botão do fone e `Ctrl+Shift+D` |
| `ptt-down` / `ptt-up` | Aperta e solta o aperte para falar |
| `ptt-toggle` | Aperta, ou solta se estiver apertado (para atalhos que não mandam o soltar da tecla) |
| `show` / `hide` / `toggle` | A janela, como o menu da bandeja e o clique no ícone dela |
| `open <link ou id>` | Abre um link de mensagem ou de canal do Discord (`https://discord.com/channels/…`) ou o ID de um canal, e traz a janela para a frente |
| `watch` | Fica rodando e escreve uma linha cada vez que o status, as não lidas ou a call mudam |
| `watch --waybar` | O mesmo, em JSON para um módulo custom do waybar |
| `watch --format text` | O mesmo, numa linha de texto (polybar e outros) |
| `mentions [n]` | As DMs não lidas e as menções (o que a Caixa de entrada mostra), da mais nova para a mais velha, em JSON: quem, onde, o começo da mensagem e um `link` para o `open`. Uma conversa que você ainda não abriu vem numa linha só, com o `text` vazio e `count` mensagens novas |
| `channels` | Servidores, canais de texto e de voz e DMs com as não lidas, em JSON, para um lançador (`open <id>` abre) |
| `presence <online\|idle\|dnd\|invisible>` | Troca o seu status |
| `volume <id> <0-200>` | O volume de alguém na call, em porcentagem, como o mixer |
| `inspect <comando>` | Roda um comando do [Inspetor](inspector.pt-BR.md): `inspect find <texto>`, `inspect tree`, `inspect el <seletor>`, `inspect net`, `inspect log`, `inspect shot arquivo.png`… (`inspect help` lista todos). Clicar e digitar só funcionam no modo demonstração ou com "Deixar o ctl clicar e digitar" ligado no Console do Inspetor |
| `help` | A lista de comandos |

A resposta vai para a saída padrão e o código de saída é 0 quando deu certo, 1 quando não (o
motivo vai para a saída de erros). Os comandos de voz respondem com o estado novo
(`{"muted":true,"deafened":false}`, `{"ptt_held":true}`), os da janela com `{"window":"shown"}`
(`hidden` ou `minimized`).

O `status` é assim (numa linha só; aqui espalhado):

```json
{"connected": true, "connection": "ready", "demo": false,
 "account": {"id": "123456789012345678", "name": "voce"},
 "window": "shown", "presence": "online", "latency_ms": 42,
 "voice": {"muted": false, "deafened": false, "mode": "push_to_talk", "ptt_held": false,
           "call": {"state": "connected", "channel_id": "…", "channel": "Geral",
                    "guild_id": "…", "guild": "Meu servidor",
                    "members": [{"id": "…", "name": "Ana", "avatar": "https://cdn.discordapp.com/avatars/…",
                                 "speaking": true, "muted": false, "deafened": false,
                                 "self": false, "volume": 1.0}]}},
 "unread": {"mentions": 3, "dms": 1, "channels": 5}}
```

Os IDs vêm como texto, como na API do Discord. `call` é `null` fora de call, e `guild_id` e
`guild` são `null` numa call de DM. `connection` é `ready`, `connecting`, `reconnecting`,
`offline`, `failed`, `rejected` ou `logged_out` (a tela de login). `mentions` conta como o número
vermelho do Discord (com as DMs); `dms` e `channels` contam as conversas e os canais de texto não
lidos, sem os que você silenciou. `presence` é `online`, `idle`, `dnd` ou `invisible`, e
`latency_ms` é o heartbeat do gateway (0 até medir). Na call, `members` lista quem está nela, com
quem fala agora: o `watch` manda uma linha quando alguém começa ou para de falar.

## Aperte para falar por um atalho

Primeiro escolha Configurações → Voz → **Aperte para falar**. A tecla escolhida lá continua
valendo com a janela em foco; o atalho abaixo acrescenta uma tecla que vale em qualquer lugar.
Numa call, o `ptt-down` transmite até o `ptt-up`, mesmo com outra janela em foco, e sair da call
solta. Fora do modo aperte para falar, os comandos respondem com um erro e não fazem nada.

**Hyprland** (`~/.config/hypr/hyprland.conf`), uma tecla segurada:

```ini
bind  = , F13, exec, larpercord ctl ptt-down
bindr = , F13, exec, larpercord ctl ptt-up
```

**Sway** (`~/.config/sway/config`; `--no-repeat` para a tecla segurada não mandar de novo):

```
bindsym --no-repeat F13 exec larpercord ctl ptt-down
bindsym --release F13 exec larpercord ctl ptt-up
```

**i3** funciona do mesmo jeito no X11 (`bindsym --release`).

**KDE Plasma**: Configurações do Sistema → Teclado → Atalhos → Adicionar novo → Comando ou script,
comando `larpercord ctl ptt-toggle`, e escolha a tecla. Os atalhos do Plasma não disparam ao
soltar, então a tecla vira um interruptor: aperta para falar, aperta de novo para parar.

**GNOME**: Configurações → Teclado → Ver e personalizar atalhos → Atalhos personalizados → `+`,
comando `larpercord ctl ptt-toggle`. Igual ao KDE: um toque fala, o próximo para.

Qualquer um deles também pode ter uma tecla de mutar: `larpercord ctl toggle-mute`.

## Barras de status

**waybar** (`~/.config/waybar/config`, e ponha `"custom/larpercord"` numa lista de módulos):

```jsonc
"custom/larpercord": {
    "exec": "larpercord ctl watch --waybar",
    "return-type": "json",
    "format": "{icon} {}",
    "format-icons": {
        "offline": "⏻", "idle": "💬", "unread": "💬", "mention": "🔴",
        "call": "🔊", "talking": "🎙", "muted": "🔇", "deafened": "🎧"
    },
    "on-click": "larpercord ctl toggle",
    "on-click-right": "larpercord ctl toggle-mute",
    "on-click-middle": "larpercord ctl toggle-deafen"
}
```

Cada linha tem `text` (o número de menções, vazio quando não há nenhuma), `alt` (o estado
principal, para o `format-icons`: `offline`, `idle`, `unread`, `mention`, `call`, `talking`,
`muted` ou `deafened`; numa call, o estado dela ganha), `class` (todos os estados que valem, para
o CSS) e `tooltip` (quem é você, a call e as contas, no idioma do app). Por exemplo, em
`~/.config/waybar/style.css`:

```css
#custom-larpercord.mention  { color: #f04747; }
#custom-larpercord.muted,
#custom-larpercord.deafened { color: #faa61a; }
#custom-larpercord.talking  { color: #43b581; }
```

Quando o app fecha (ou o Controle externo é desligado), o módulo mostra `offline` e o comando
tenta de novo a cada 3 segundos, então ele volta sozinho quando o app abre.

**polybar**:

```ini
[module/larpercord]
type = custom/script
exec = larpercord ctl watch --format text
tail = true
click-left = larpercord ctl toggle
click-right = larpercord ctl toggle-mute
```

A linha de texto mostra a call e o estado dela, `@` com as menções, `DM` com as conversas não
lidas e `#` com os canais não lidos, por exemplo `Geral · mudo · @3 · DM 1 · #5`. Fica vazia
quando não há nada para mostrar.

Para os seus scripts, o `watch` (sem opções) escreve o mesmo JSON do `status`, uma linha por
mudança. Com o `jq`:

```sh
larpercord ctl unread | jq .mentions
larpercord ctl watch | jq --unbuffered -r '.unread.mentions'
```

## Windows

Os mesmos comandos, com o caminho inteiro quando o `larpercord.exe` não está no `PATH`
(`%LOCALAPPDATA%\Programs\larperCord\larpercord.exe` com o instalador). No Windows a tecla do
aperte para falar de Configurações → Voz já vale com outra janela em foco, então o `ctl` é para o
resto: outras teclas de atalho, scripts, um Stream Deck.

**AutoHotkey v2**:

```ahk
#Requires AutoHotkey v2.0
lc := EnvGet("LOCALAPPDATA") "\Programs\larperCord\larpercord.exe"
^!m:: Run('"' lc '" ctl toggle-mute', , "Hide")
^!d:: Run('"' lc '" ctl toggle-deafen', , "Hide")
^!l:: Run('"' lc '" ctl toggle', , "Hide")
F13:: Run('"' lc '" ctl ptt-down', , "Hide")
F13 up:: Run('"' lc '" ctl ptt-up', , "Hide")
```

**Um atalho**: botão direito na área de trabalho → Novo → Atalho, destino
`"%LOCALAPPDATA%\Programs\larperCord\larpercord.exe" ctl toggle-mute`, e nas Propriedades dele
escolha uma Tecla de atalho.

O `larpercord.exe` da release é um programa de janela, então o `cmd` e o PowerShell não esperam
por ele e mostram a saída depois do próximo prompt. Para ler a resposta num terminal, passe por
um cano: `larpercord ctl status | more` (cmd) ou `larpercord ctl status | Out-String`
(PowerShell). O código de saída só existe quando o terminal esperou (`start /wait` no cmd, ou um
cano).

## Testando com a demonstração

A demonstração (`--demo`), o QA e o `--shot` não abrem a porta, então nunca atrapalham o
larperCord que você usa. Com `LARPER_CTL=1` eles abrem, em outro arquivo (`ctl-demo.port`);
ponha a variável no comando também:

```sh
LARPER_CTL=1 larpercord --demo &
LARPER_CTL=1 larpercord ctl status
```

`LARPER_CTL=/algum/caminho/ctl.port` usa esse arquivo, nos dois lados.

## O protocolo

Para falar com ele sem o comando, de um programa seu: leia `<porta> <chave>` do arquivo, conecte
em `127.0.0.1:<porta>` e mande a chave como primeira linha. Depois, um comando por linha; cada
resposta é `OK` ou `ERR <código> <mensagem>`, as linhas do corpo e uma linha só com `.` (uma linha
do corpo que começa com `.` ganha outro `.` na frente). O `watch` só termina com o `.` quando o app
fecha. Os códigos de erro (`not_ptt`, `no_call`, `not_found`, `timeout`…) nunca mudam entre
versões. Os detalhes estão no começo de [`src/app_ctl.zig`](../src/app_ctl.zig). Um comando
espera no máximo 5 segundos pelo app (depois vem `ERR timeout`), e ficam no máximo 8 conexões
abertas ao mesmo tempo.
