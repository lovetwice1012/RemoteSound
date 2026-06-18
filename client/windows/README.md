# RemoteSound Windows WinForms Client

Windows のスピーカー出力を WASAPI ループバックで取得し、RemoteSound iOS サーバへ WebSocket で送信する WinForms クライアントです。

## 機能

- スピーカー出力デバイスの選択
- 48 kHz / stereo / pcm_s16le / interleaved 送信
- 接続先 URL、ソース名、Client ID、最後に使った出力デバイス、ゲイン設定の保存
- 最近使った接続先 URL の履歴
- 自動再接続
- Windows 11 では Mica/Backdrop 風の透明感ある外観

## 必要環境

- Windows 10 以降
- .NET 8 SDK
- NuGet パッケージ: NAudio 2.3.0

## ビルド

```powershell
cd client\windows\RemoteSound.WinForms
dotnet restore
dotnet build -c Release
```

## 実行

```powershell
dotnet run -c Release
```

## 使い方

1. iPhone/iPad 側で RemoteSound を起動します。
2. アプリに表示されている WebSocket 接続先を Windows クライアントの「接続先」に入力します。
   - 例: `ws://192.168.1.23:8080`
3. 「スピーカー」でキャプチャしたい Windows の出力デバイスを選びます。
4. `Connect` を押します。
5. Windows 上で鳴っている音が RemoteSound に送られます。

## 注意

- WASAPI ループバックは、選択した出力デバイスで実際に再生されている音を取得します。
- 一部の排他モード再生アプリ、DRM 保護コンテンツ、特殊な仮想オーディオデバイスでは取得できない場合があります。
- RemoteSound サーバ側は現在 `48 kHz stereo pcm_s16le` を要求します。このクライアントは内部で 48 kHz stereo PCM16 に変換して送信します。
