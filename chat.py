#!/usr/bin/env python3
"""
chat.py - result-endpoint.md を参照して Ollama (gpt-oss) と簡易チャットするCLIツール。

deploy.ps1 が result-endpoint.md に書き出した Public_Endpoint の URL・API_Key・
モデル名を読み取り、Ollama の /api/generate エンドポイントへリクエストを送信して
テキストのみのシンプルな対話（チャット）を行う。

前提:
- result-endpoint.md が deploy.ps1 実行によって生成済みであること
  （STATUS: Ready の状態、すなわちモデル準備確認まで完了していること）。
- Python 3.8+ のみで動作する（標準ライブラリのみを使用し、追加の pip install は不要）。

使い方:
    python chat.py
    python chat.py --file path\to\result-endpoint.md
    python chat.py --no-stream
    python chat.py --timeout 180
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

DEFAULT_RESULT_FILE = "result-endpoint.md"
DEFAULT_TIMEOUT_SECONDS = 120

# result-endpoint.md 内の各項目を抽出する正規表現。
# DeploymentMonitor.psm1 の Write-ResultEndpointFile が出力する形式
# （"- URL: <value>" 等）に対応する。
_FIELD_PATTERNS = {
    "url": re.compile(r"^-\s*URL:\s*(.+?)\s*$", re.MULTILINE),
    "api_key": re.compile(r"^-\s*API_KEY:\s*(.+?)\s*$", re.MULTILINE),
    "model": re.compile(r"^-\s*MODEL:\s*(.+?)\s*$", re.MULTILINE),
    "status": re.compile(r"^-\s*STATUS:\s*(.+?)\s*$", re.MULTILINE),
}


class ResultEndpointError(Exception):
    """result-endpoint.md の読み込み・解析に失敗したことを示す例外。"""


class EndpointInfo:
    """result-endpoint.md から読み取ったデプロイ結果情報。"""

    def __init__(self, url: str, api_key: str, model: str, status: str) -> None:
        self.url = url.rstrip("/")
        self.api_key = api_key
        self.model = model
        self.status = status


def parse_result_endpoint_file(path: Path) -> EndpointInfo:
    """result-endpoint.md を読み込み、URL・API_KEY・MODEL・STATUS を抽出する。

    Args:
        path: result-endpoint.md のパス。

    Returns:
        解析結果を保持する EndpointInfo。

    Raises:
        ResultEndpointError: ファイルが存在しない、または必須項目
            （URL・API_KEY・MODEL）が見つからない場合。
    """
    if not path.is_file():
        raise ResultEndpointError(
            f"{path} が見つかりません。先に deploy.ps1 を実行してデプロイを完了させてください。"
        )

    try:
        content = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ResultEndpointError(f"{path} の読み込みに失敗しました: {exc}") from exc

    values: dict[str, Optional[str]] = {}
    for key, pattern in _FIELD_PATTERNS.items():
        match = pattern.search(content)
        values[key] = match.group(1).strip() if match else None

    missing = [key for key in ("url", "api_key", "model") if not values.get(key)]
    if missing:
        raise ResultEndpointError(
            f"{path} から必須項目（{', '.join(missing)}）を読み取れませんでした。"
            " deploy.ps1 が正常に完了しているか確認してください。"
        )

    return EndpointInfo(
        url=values["url"],  # type: ignore[arg-type]
        api_key=values["api_key"],  # type: ignore[arg-type]
        model=values["model"],  # type: ignore[arg-type]
        status=values.get("status") or "Unknown",
    )


def call_generate(
    endpoint: EndpointInfo,
    prompt: str,
    *,
    stream: bool,
    timeout: int,
) -> str:
    """Ollamaの /api/generate エンドポイントを呼び出し、応答テキストを返す。

    Args:
        endpoint: 接続先エンドポイント情報。
        prompt: ユーザーが入力したプロンプト文字列。
        stream: Trueの場合、応答をストリーミングで受信しつつ順次表示する
            （ストリーミング表示中も最終的な全文を返す）。
        timeout: HTTPリクエストのタイムアウト秒数。

    Returns:
        モデルが生成した応答テキストの全文。

    Raises:
        urllib.error.URLError: 接続エラー（DNS解決失敗、タイムアウト等）。
        urllib.error.HTTPError: HTTPエラー応答（401: APIキー不一致、5xx等）。
    """
    url = f"{endpoint.url}/api/generate"
    payload = {
        "model": endpoint.model,
        "prompt": prompt,
        "stream": stream,
    }
    body = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-API-Key": endpoint.api_key,
        },
    )

    full_response_parts: list[str] = []

    with urllib.request.urlopen(request, timeout=timeout) as response:
        if not stream:
            raw = response.read().decode("utf-8")
            data = json.loads(raw)
            text = data.get("response", "")
            print(text)
            return text

        # ストリーミングモード: Ollamaは1行に1つのJSONオブジェクトを改行区切りで返す
        # （JSON Lines形式）。行ごとに読み取り、"response"の断片を都度出力する。
        for raw_line in response:
            line = raw_line.decode("utf-8").strip()
            if not line:
                continue
            try:
                chunk = json.loads(line)
            except json.JSONDecodeError:
                continue

            piece = chunk.get("response", "")
            if piece:
                print(piece, end="", flush=True)
                full_response_parts.append(piece)

            if chunk.get("done"):
                break

        print()  # ストリーミング出力の末尾に改行を入れる

    return "".join(full_response_parts)


def run_chat_loop(endpoint: EndpointInfo, *, stream: bool, timeout: int) -> None:
    """標準入力からプロンプトを読み込み、応答を表示し続けるチャットループ。

    'exit'、'quit'、または空入力でループを終了する。Ctrl+C（KeyboardInterrupt）
    やEOF（Ctrl+Dなど）でも安全に終了する。
    """
    print(f"接続先: {endpoint.url}")
    print(f"モデル: {endpoint.model}")
    if endpoint.status.lower() != "ready":
        print(
            f"警告: result-endpoint.md の STATUS が '{endpoint.status}' です"
            "（モデル準備が完了していない可能性があります）。"
        )
    print("プロンプトを入力してください。終了するには 'exit' または 'quit' と入力してください。")
    print("-" * 60)

    while True:
        try:
            prompt = input("You> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            print("チャットを終了します。")
            break

        if not prompt:
            continue

        if prompt.lower() in ("exit", "quit"):
            print("チャットを終了します。")
            break

        print("Bot> ", end="" if stream else "\n", flush=True)

        try:
            call_generate(endpoint, prompt, stream=stream, timeout=timeout)
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                print(
                    "エラー: 認証に失敗しました（401）。"
                    " result-endpoint.md のAPI_Keyが正しいか確認してください。",
                    file=sys.stderr,
                )
            else:
                print(f"エラー: HTTPエラーが発生しました（{exc.code}）: {exc.reason}", file=sys.stderr)
        except urllib.error.URLError as exc:
            print(
                f"エラー: エンドポイントへの接続に失敗しました: {exc.reason}."
                " Container Appがスケールダウンしている場合、初回リクエストの応答に"
                " 時間がかかることがあります。しばらく待って再試行してください。",
                file=sys.stderr,
            )
        except json.JSONDecodeError as exc:
            print(f"エラー: 応答の解析に失敗しました: {exc}", file=sys.stderr)

        print()


def build_arg_parser() -> argparse.ArgumentParser:
    """コマンドライン引数パーサーを構築する。"""
    parser = argparse.ArgumentParser(
        description=(
            "result-endpoint.md を参照して、Ollama (gpt-oss) とテキストのみの"
            "簡易チャットを行うCLIツール。"
        )
    )
    parser.add_argument(
        "--file",
        default=DEFAULT_RESULT_FILE,
        help=f"result-endpoint.md のパス（既定値: {DEFAULT_RESULT_FILE}）",
    )
    parser.add_argument(
        "--no-stream",
        action="store_true",
        help="ストリーミング応答を無効化し、応答全文が完成してから一度に表示する。",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"HTTPリクエストのタイムアウト秒数（既定値: {DEFAULT_TIMEOUT_SECONDS}）",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    """エントリーポイント。終了コードを返す（0: 正常終了, 1: エラー）。"""
    args = build_arg_parser().parse_args(argv)

    try:
        endpoint = parse_result_endpoint_file(Path(args.file))
    except ResultEndpointError as exc:
        print(f"エラー: {exc}", file=sys.stderr)
        return 1

    run_chat_loop(endpoint, stream=not args.no_stream, timeout=args.timeout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
