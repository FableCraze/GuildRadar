# GuildRadar

Addon para **World of Warcraft 3.3.5a** que permite visualizar, no mapa-múndi, a localização dos membros da guilda que também estejam utilizando o addon.

O GuildRadar foi criado por **mim** para facilitar a localização e o acompanhamento dos membros da guilda sem depender de grupo, raid ou compartilhamento manual de coordenadas.

## Funcionalidades

- Exibe membros da guilda diretamente no mapa.
- Usa o ícone correspondente à classe de cada personagem.
- Compartilha coordenadas específicas para cada layer do mapa.
- Mantém o posicionamento correto com o mapa maximizado ou minimizado.
- Funciona sem exigir que o jogador abra o mapa ou altere manualmente o zoom.
- Mostra no tooltip:
  - nome do personagem;
  - nível;
  - classe;
  - rank da guilda;
  - vida atual e vida máxima;
  - barra visual de vida.
- Remove automaticamente do mapa jogadores que deixaram de enviar atualizações.

## Compatibilidade

- World of Warcraft 3.3.5a
- Interface `30300`
- Warmane e outros servidores privados compatíveis com as APIs padrão de addons do cliente 3.3.5a

Para que um membro apareça no mapa, os dois jogadores precisam:

1. Estar na mesma guilda.
2. Estar online.
3. Ter uma versão compatível do GuildRadar instalada e ativada.

## Instalação

1. Baixe ou clone este repositório.
2. Coloque a pasta `GuildRadar` dentro de:

```text
World of Warcraft/Interface/AddOns/
```

A estrutura final deve ficar assim:

```text
World of Warcraft
└── Interface
    └── AddOns
        └── GuildRadar
            ├── GuildRadar.lua
            ├── GuildRadar.toc
            └── README.md
```

3. Feche completamente o World of Warcraft caso ele esteja aberto.
4. Abra o jogo novamente.
5. Na tela de seleção de personagens, clique em **AddOns** e confirme que o GuildRadar está ativado.

## Comandos

| Comando | Descrição |
|---|---|
| `/gr` | Mostra os comandos disponíveis. |
| `/gr on` | Ativa o compartilhamento. |
| `/gr off` | Desativa o compartilhamento. |
| `/gr status` | Mostra o estado do addon e a quantidade de membros detectados. |
| `/gr tamanho 18` | Altera o tamanho dos marcadores. Aceita valores entre 12 e 32. |

O comando legado `/guildradar` também é reconhecido pela versão atual.

## Como funciona

### Coleta de coordenadas

O cliente do WoW 3.3.5a normalmente fornece a posição do personagem em relação ao mapa atualmente selecionado. Para representar corretamente uma mesma localização nos diferentes layers, o GuildRadar coleta e armazena coordenadas separadas para cada combinação de:

```text
mapa + layer
```

A coleta começa na zona atual do personagem e percorre somente a hierarquia de mapas relacionada àquela localização.

Quando o mapa está aberto, o addon não altera zoom, zona ou floor. Nesse momento, ele reutiliza o último conjunto válido de coordenadas, evitando qualquer mudança visível no mapa do jogador.

### Compartilhamento

As informações são transmitidas pelo canal interno de mensagens de addon da guilda:

```lua
SendAddonMessage(prefixo, mensagem, "GUILD")
```

Cada atualização pode conter várias posições, uma para cada layer detectado. Os pacotes incluem uma sequência e uma contagem total. O cliente que recebe somente substitui o conjunto anterior depois que todos os pacotes da atualização foram recebidos.

Entre os dados compartilhados estão:

- nome do remetente, fornecido pelo evento do jogo;
- mapa;
- layer;
- coordenadas X e Y;
- nível;
- classe;
- rank da guilda;
- vida atual;
- vida máxima.

As mensagens são recebidas apenas por personagens da guilda que estejam executando o addon na versão compatível com o mesmo protocolo.

### Exibição dos marcadores

Ao abrir ou atualizar o mapa, o GuildRadar procura a coordenada recebida que corresponde exatamente ao mapa e ao layer atualmente exibidos.

O marcador é posicionado proporcionalmente ao tamanho atual do `WorldMapButton`, permitindo que continue alinhado tanto no mapa maximizado quanto no mapa minimizado.

### Atualizações e expiração

O addon verifica periodicamente mudanças de:

- localização;
- layer;
- vida atual;
- vida máxima.

Quando não há mudanças, uma atualização de manutenção é enviada em intervalos maiores. Um jogador deixa de ser exibido quando nenhuma mensagem válida é recebida dentro do tempo de expiração configurado.

## Por que o GuildRadar é permitido na Warmane?

O GuildRadar funciona inteiramente dentro do sistema padrão de addons do World of Warcraft 3.3.5a. Ele é escrito em Lua e utiliza somente funções disponibilizadas pelo próprio cliente, como leitura do mapa, criação de elementos de interface e `SendAddonMessage`.

O addon não depende de um programa externo, não modifica o executável do jogo e não realiza ações de movimento ou combate pelo personagem. Sua função é apresentar informações compartilhadas voluntariamente por outros usuários do mesmo addon.

As regras públicas da Warmane proíbem programas de trapaça, bots e automações que controlem a jogabilidade. Em uma discussão publicada no fórum da Warmane em abril de 2026, foi explicado que um addon pode enviar mensagens periodicamente sem intervenção do usuário; a distinção apresentada é que o addon não deve controlar o personagem ou realizar interações automatizadas no jogo.

Com base nessa distinção, o comportamento atual do GuildRadar se enquadra no uso normal de addons:

- executa dentro do ambiente Lua do cliente;
- usa APIs padrão disponíveis aos addons;
- apenas troca informações pelo canal de addon;
- adiciona elementos visuais ao mapa;
- não controla o personagem.

### Referências

- [Warmane — Players Code of Conduct](https://forum.warmane.com/showthread.php?t=65037)
- [Warmane Forum — Need to check before possible rule break](https://forum.warmane.com/showthread.php?p=3280311)
- [Warmane Forum — Addon / Macro](https://forum.warmane.com/showthread.php?t=421785)

> **Aviso:** este projeto é independente e não possui vínculo oficial com a Warmane. A explicação acima é baseada no funcionamento atual do addon e nas regras públicas disponíveis. As políticas de qualquer servidor podem ser alteradas pelos respectivos administradores.

## Privacidade

O GuildRadar não envia informações para sites, APIs externas ou bancos de dados.

A comunicação ocorre somente dentro do jogo, pelo canal de mensagens de addon da guilda. As posições não são exibidas para jogadores que não estejam na mesma guilda e não estejam usando uma versão compatível do addon.

## Autoria

Desenvolvido por **Valber Lima**.

GitHub: [@FableCraze](https://github.com/FableCraze)
