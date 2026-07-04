# テスト実行手順

このディレクトリには、`modules/` 配下の各PowerShellモジュール（`EnvFile.psm1`, `ResourceState.psm1`, `GpuProfile.psm1`, `NginxConfig.psm1`, `AuthDecision.psm1`, `OllamaStartup.psm1`, `DeploymentMonitor.psm1`, `ContainerAppSpec.psm1`）に対する単体テスト・プロパティベーステスト、および `deploy.ps1`/`teardown.ps1` の統合テストを配置します。

テストフレームワークには [Pester](https://pester.dev/) を使用します。

## 前提条件

Pester がインストールされていることを前提とします。未インストールの場合は以下でインストールしてください（PowerShell 7+ 推奨）。

```powershell
Install-Module -Name Pester -Scope CurrentUser -Force -SkipPublisherCheck
```

インストール済みバージョンの確認:

```powershell
Get-Module -ListAvailable Pester
```

## テストの実行方法

リポジトリルートから、`tests/` ディレクトリ配下のすべてのテストを実行する場合:

```powershell
Invoke-Pester -Path ./tests
```

詳細な出力（各テストケース名を表示）を確認したい場合:

```powershell
Invoke-Pester -Path ./tests -Output Detailed
```

特定のテストファイルのみ実行する場合（例: `EnvFile.psm1` のテスト）:

```powershell
Invoke-Pester -Path ./tests/EnvFile.Tests.ps1
```

## 命名規約

- テストファイルは対象モジュール名に合わせて `<ModuleName>.Tests.ps1` とする（例: `EnvFile.Tests.ps1`）。
- プロパティベーステストには、対応する `design.md` のプロパティ番号をコメントで明記する:
  ```powershell
  # Feature: ollama-gpt-oss-container-apps, Property {number}: {property_text}
  ```
- プロパティベーステストは各プロパティにつき最低100イテレーションのランダム入力で実行する。
