# Atualização do botão "+ Nova Área"

A arquitetura atual do Temenos usa:

```text
Temenos/
├── src/
│   ├── Config.ps1
│   ├── DesktopEvents.ps1
│   ├── Indicator.ps1
│   ├── DesktopActions.ps1
│   ├── NewDesktop.ps1
│   └── Temenos.ps1
├── Temenos.json
└── assets/
    └── icons/
        └── NovaArea_ultra.ico
```

## Instalação

1. Copie `src/DesktopActions.ps1` e `src/NewDesktop.ps1` para o `src/` do repositório Temenos.
2. Coloque `NovaArea_ultra.ico` em `assets/icons/`.
3. Execute `Criar Atalho Nova Area.vbs` a partir da raiz do repositório.
4. O script cria/atualiza `+ Nova Área.lnk` na Área de Trabalho.
5. Fixe o atalho na barra de tarefas.

O atalho executa explicitamente:

```text
src\NewDesktop.ps1
```

e não depende de caminhos fixos como `C:\Users\Cliente\...`.

## Observação

O código atual do `Temenos.ps1` não implementa criação de novas áreas como módulo. Estes dois módulos separam essa ação do monitor principal sem misturar a criação de desktops com a lógica de configuração, eventos e indicador.
