# docs/

This directory stores static assets referenced in the GitHub README files.

## Donate QR Codes

Place the following PNG files here to display them in the README and in the app's About → Donate panel:

| File | Description |
|------|-------------|
| `donate_wechat.png` | 微信赞赏码 / WeChat Pay QR code |
| `donate_alipay.png` | 支付宝收款码 / Alipay QR code |

The same files (`donate_wechat.png` and `donate_alipay.png`) should also be copied to
`MacKeyValue/Resources/` so that the built `.app` bundle can load them at runtime.

The `build.sh` script already copies everything in `MacKeyValue/Resources/` into the app bundle,
so placing the files there is sufficient for both development and release builds.
