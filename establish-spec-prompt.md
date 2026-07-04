Azure Container Apps サーバーレス GPU に Ollama を使用して OpenAI gpt-oss モデルをデプロイする _ Microsoft Learn.htmlの手順に従いAzure Container AppsにGPUリソースでOllamaを構築して、gpt-oss-20bをデプロイしてエンドポイントとして利用するプロジェクトです。

.env.example、.envに指定したサブスクリプション、リソースグループ、Azureポータル認証情報を使い、Azure CLIですべての環境設定を行い、Ollamaのgpt-oss-20bのエンドポイントをAPIキー付きでインターネットの公開するところまでを完全自動で提供します。

このプロジェクトのスペックをcontainer-apps_specs.mdにまとめてください