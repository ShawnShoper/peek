# PEEK 隐私政策 / Privacy Policy

最后更新：2026 年 8 月 24 日
Last updated: August 24, 2026

PEEK 是一款 macOS 菜单栏工具，提供应用与文件查找、截图、OCR、二维码识别和翻译功能。本政策说明 PEEK 如何处理你的数据与系统权限。

PEEK is a macOS menu bar utility for finding apps and files, capturing screenshots, recognizing text and QR codes, and translating text. This policy explains how PEEK handles your data and system permissions.

## 1. 核心原则 / Our approach

- PEEK 默认在你的 Mac 本机处理数据，不包含广告、用户跟踪或自动上传的分析服务。
- PEEK 没有用于接收搜索词、文件索引、截图、OCR 结果或二维码结果的开发者服务器。
- 只有当你自行配置并启用百度翻译或 Google 翻译，并主动点击“翻译”或按 `Command + Enter` 提交后，待翻译文字才会直接发送给所有已启用且配置完整的服务商。

- By default, PEEK processes data locally on your Mac and does not include advertising, user tracking, or automatic analytics uploads.
- PEEK has no developer-operated server that receives your searches, file index, screenshots, OCR results, or QR-code results.
- Text is sent off-device only after you configure and enable Baidu Translate or Google Translate and actively submit with Translate or `Command + Enter`. It is sent directly to every enabled and fully configured provider.

## 2. 本机处理的数据 / Data processed locally

### 文件查找 / File search

PEEK 会为系统应用目录和你明确授权的目录建立本地索引。索引可能包含应用、文件和文件夹的名称、路径、类型、大小、时间信息、隐藏状态、应用版本和搜索别名。PEEK 不会把文件正文复制到索引中；文件或图片预览只会在你查看对应结果时按需读取。

为了改进本机排序，PEEK 可以在本地记录各应用通过 PEEK 打开的次数。搜索设置、授权目录、安全作用域书签、排除项、快捷键和部分界面状态也会保存在本机。索引进度与日志可能在设置页显示当前处理的本地路径，这些信息不会自动上传。

PEEK builds a local index for system application folders and folders that you explicitly authorize. The index may include names, paths, types, sizes, timestamps, hidden status, app versions, and search aliases for apps, files, and folders. PEEK does not copy document contents into the index. File and image previews are read on demand only when you view the relevant result.

To improve local ranking, PEEK may store how often an app is opened through PEEK. Search settings, authorized folders, security-scoped bookmarks, exclusions, shortcuts, and some interface state are also stored locally. Index progress and logs may show the local path currently being processed in Settings; this information is not uploaded automatically.

### 截图、OCR 与二维码 / Screenshots, OCR, and QR codes

截图像素、标注、OCR 和二维码识别均使用 macOS 系统能力在本机处理。结果只会在你主动选择时复制到系统剪贴板、保存到你指定的位置、钉在屏幕上，或交给其他应用打开。PEEK 不会自动上传这些内容。

如果你选择打开二维码中的网址，macOS 会把网址交给相应浏览器；此后的网络访问由浏览器和目标网站负责。

Screenshot pixels, annotations, OCR, and QR-code recognition are processed locally using macOS system capabilities. Results are copied to the system clipboard, saved to a location you choose, pinned on screen, or opened in another app only when you request that action. PEEK does not upload this content automatically.

If you choose to open a URL found in a QR code, macOS passes it to the appropriate browser. Any subsequent network activity is handled by the browser and destination website.

### Apple 本地翻译 / Apple on-device translation

在支持的 macOS 版本上，Apple 翻译使用系统管理的本地语言模型。PEEK 不会把使用此功能输入的正文发送给百度、Google 或 PEEK 自有服务器。语言包的下载和管理由 macOS 与 Apple 负责。

On supported macOS versions, Apple translation uses language models managed by the system. PEEK does not send text entered for this feature to Baidu, Google, or a PEEK-operated server. Language-pack downloads and management are handled by macOS and Apple.

## 3. 可选云翻译 / Optional cloud translation

百度翻译和 Google 翻译默认关闭。只有在你自行提供凭据、启用相应服务并主动提交翻译后，PEEK 才会调用该服务；如果两者都已启用且配置完整，同一次提交会发送给两家服务商。

Baidu Translate and Google Translate are disabled by default. PEEK contacts a provider only after you supply your own credentials, enable that provider, and actively submit a translation. If both providers are enabled and fully configured, the same submission is sent to both.

### 百度翻译 / Baidu Translate

启用后，PEEK 会通过 HTTPS 将待翻译文字、源语言、目标语言、你的百度 APP ID、随机 salt 和本机生成的签名直接发送到百度翻译开放平台。百度密钥保存在 macOS 钥匙串中，用于在本机生成请求签名，不会作为明文请求字段发送。

When enabled, PEEK sends the text, source and target languages, your Baidu APP ID, a random salt, and a locally generated signature directly to the Baidu Translate Open Platform over HTTPS. Your Baidu secret is stored in macOS Keychain and is used locally to generate the request signature; it is not sent as a plaintext request field.

### Google 翻译 / Google Translate

启用后，PEEK 会通过 HTTPS 将待翻译文字、源语言（如已指定）、目标语言和你的 Google Cloud Translation API Key 直接发送到 Google Cloud Translation。API Key 必须随请求发送给 Google 用于身份验证。

When enabled, PEEK sends the text, source language (when specified), target language, and your Google Cloud Translation API key directly to Google Cloud Translation over HTTPS. The API key must be sent to Google with the request for authentication.

云翻译请求不会经过 PEEK 自有服务器，PEEK 也不会建立云端翻译历史。服务商会收到完成请求所需的正文、凭据或签名以及常规网络信息，并可能依据其自身条款与隐私政策处理或保留这些数据。启用前，请阅读相应服务商的政策并确认你有权发送相关文字。

Cloud translation requests do not pass through a PEEK-operated server, and PEEK does not create a cloud translation history. The provider receives the text, credentials or signature needed to service the request, and ordinary network information. The provider may process or retain that data under its own terms and privacy policy. Before enabling a provider, review its policy and make sure you are authorized to send the text.

PEEK 不会出售云翻译数据，也不会授权服务商将这些数据用于广告或跨应用跟踪。第三方服务只用于完成你主动提交的翻译请求，并应依据其公开政策和适用法律提供与本政策一致的保护。如果服务商的政策发生实质变化，PEEK 会重新评估该集成并更新本政策或移除相关功能。

PEEK does not sell cloud-translation data or authorize providers to use it for advertising or cross-app tracking. A provider is used only to fulfill a translation request that you submit and is expected to protect the data consistently with this policy, its published policy, and applicable law. If a provider materially changes its practices, PEEK will reassess the integration and update this policy or remove the feature.

## 4. API 凭据 / API credentials

百度密钥和 Google API Key 保存在 macOS 钥匙串中；百度 APP ID 和服务开关保存在 PEEK 的本机偏好设置中。PEEK 不会把凭据发送到 PEEK 自有服务器，也不会写入诊断日志。调用云翻译时，必要的身份验证数据会按上述方式直接发送给对应服务商。

Baidu secrets and Google API keys are stored in macOS Keychain. The Baidu APP ID and provider switches are stored in PEEK's local preferences. PEEK does not send credentials to a PEEK-operated server or write them to diagnostic logs. When cloud translation is used, the authentication data required by the provider is sent directly as described above.

## 5. 系统权限 / System permissions

PEEK 只在相应功能需要时请求以下权限：

- **文件与文件夹**：读取你通过系统文件选择器明确授权的位置，并为其建立本地索引；文件移动、复制或保存只在你主动执行时发生。
- **屏幕录制**：读取屏幕像素，用于区域截图、滚动截图、OCR 截图和相关预览。
- **辅助功能 / Post Event**：在你启动滚动截图时识别滚动区域并发送滚动事件；不会用于后台记录键盘输入。
- **网络访问**：仅用于你启用的百度或 Google 云翻译，以及你主动打开的外部链接。
- **剪贴板**：在你选择粘贴、复制或完成截图等操作时读取或写入相关内容。

PEEK requests the following permissions only when needed for a feature:

- **Files and folders:** Reads locations you explicitly authorize through the system file picker and builds a local index. Moving, copying, or saving files occurs only when you request it.
- **Screen Recording:** Reads screen pixels for region capture, scrolling capture, OCR capture, and related previews.
- **Accessibility / Post Event:** Identifies scrollable areas and sends scrolling events when you start scrolling capture. It is not used to record keyboard input in the background.
- **Network access:** Used only for Baidu or Google cloud translation that you enable and for external links that you choose to open.
- **Clipboard:** Reads or writes relevant content when you choose actions such as Paste, Copy, or completing a screenshot.

受保护窗口、DRM 内容和 macOS 禁止读取的文件不会被绕过。PEEK 不修改、删除或规避 macOS 的隐私权限数据库。

PEEK does not bypass protected windows, DRM content, files blocked by macOS, or the macOS privacy-permission database.

## 6. 保留、删除与撤回 / Retention, deletion, and withdrawal

- 本地索引和设置会保留在 Mac 上，以便应用重启后继续使用。
- 从 PEEK 的搜索设置中删除授权目录后，该目录会停止参与搜索，相关索引记录会在本机清理流程中移除。
- 你可以在 PEEK 设置中关闭云翻译并删除保存的凭据。建议在卸载 PEEK 前先删除凭据，因为 macOS 可能在应用卸载后继续保留钥匙串项目。
- 你可以在“系统设置 > 隐私与安全性”中随时撤销屏幕录制、辅助功能和文件访问权限。
- 系统剪贴板中的内容由 macOS 管理；你导出的文件由你自行管理和删除。
- PEEK 不在自有服务器保留云翻译正文。服务商的数据保留与删除规则由其各自政策决定，请直接向相应服务商行使相关权利。
- 如需清除全部本机数据，请先退出 PEEK，删除已保存的云翻译凭据，然后移除 PEEK 及其由 macOS 管理的应用数据。

- The local index and settings remain on your Mac so they can be used after the app restarts.
- Removing an authorized folder from PEEK Search settings stops it from participating in search, and related index records are removed by the local cleanup process.
- You can disable a cloud provider and delete its saved credentials in PEEK Settings. Remove credentials before uninstalling PEEK because macOS may preserve Keychain items after an app is removed.
- You can revoke Screen Recording, Accessibility, and file access at any time in **System Settings > Privacy & Security**.
- Clipboard content is managed by macOS. Files that you export remain under your control and can be deleted by you.
- PEEK does not retain cloud-translation text on a PEEK-operated server. Provider retention and deletion are governed by the provider's own policy; contact that provider to exercise applicable rights.
- To remove all local data, quit PEEK, delete saved cloud-translation credentials, and then remove PEEK and its macOS-managed app data.

## 7. 诊断信息 / Diagnostics

PEEK 不集成第三方崩溃上报或用户行为分析服务。应用和 macOS 可能在本机保存运行日志。PEEK 的可复制诊断信息不应包含文件正文、截图、搜索词或 API 密钥；你仍应在主动提交问题前检查准备分享的内容。

PEEK does not integrate third-party crash reporting or behavioral analytics services. The app and macOS may keep operational logs locally. PEEK's copyable diagnostics are designed not to include document contents, screenshots, search terms, or API keys, but you should still review anything before sharing it in a support request.

## 8. 儿童隐私 / Children's privacy

PEEK 不面向儿童收集个人信息，也不包含账号系统、广告或跟踪功能。

PEEK does not target children for personal-data collection and does not include accounts, advertising, or tracking.

## 9. 政策变更 / Changes to this policy

如果 PEEK 的数据处理方式发生实质变化，本政策会同步更新，并修改顶部的更新日期。影响用户选择的重大变更会在应用或发布说明中提示。

If PEEK materially changes how it handles data, this policy will be updated and the date above will change. Significant changes that affect user choices will also be communicated in the app or release notes.

## 10. 联系我们 / Contact

如对隐私、数据删除或 PEEK 的使用有疑问，请通过公开支持入口提交问题：

For privacy, data-deletion, or product questions, contact the project through the public support channel:

- [PEEK GitHub Issues](https://github.com/ShawnShoper/peek/issues)

GitHub Issues 默认公开。提交前请删除文件路径、截图、搜索词、API 凭据和其他敏感信息。你主动提交的内容由 GitHub 按其政策托管。

GitHub Issues are public by default. Remove file paths, screenshots, search terms, API credentials, and other sensitive information before posting. Content you submit is hosted by GitHub under its own policies.
