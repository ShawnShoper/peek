# PEEK Privacy Policy

Last updated: August 27, 2026

PEEK is a macOS menu bar utility for finding apps and files, capturing screenshots, recognizing text and QR codes, and translating text. This policy explains how PEEK handles your data and system permissions.

## 1. Our approach

- By default, PEEK processes data locally on your Mac and does not include advertising, user tracking, or automatic analytics uploads.
- PEEK has no developer-operated server that receives your searches, file index, screenshots, OCR results, or QR-code results.
- Text is sent off-device only after you configure and enable Baidu Translate or Google Translate and actively submit with Translate or `Command + Enter`. It is sent directly to every enabled and fully configured provider.

## 2. Data processed locally

### File search

PEEK builds a local index for system application folders and folders that you explicitly authorize. The index may include names, paths, types, sizes, timestamps, hidden status, app versions, and search aliases for apps, files, and folders. PEEK does not copy document contents into the index. File and image previews are read on demand only when you view the relevant result.

To improve local ranking, PEEK may store how often an app is opened through PEEK. Search settings, authorized folders, security-scoped bookmarks, exclusions, shortcuts, and some interface state are also stored locally. Index progress and logs may show the local path currently being processed in Settings; this information is not uploaded automatically.

### Clipboard history

PEEK ignores clipboard content marked as concealed, transient, auto-generated, or from 1Password. This depends on the source app supplying the marker and cannot identify all unmarked sensitive information; exclude sensitive apps when appropriate. Ordinary history is stored in the local sandbox without additional encryption. Updating PEEK does not automatically clear older history; you can clear it in Settings.

When Clipboard History is enabled, PEEK observes system clipboard changes in the background and stores supported text, rich text, images, web addresses, and file or folder references inside the app sandbox. History keeps at most 100 items and is protected by a 256 MB local storage limit. The oldest items are removed when either limit is reached, and individual items larger than 32 MB are not saved.

Clipboard history is not uploaded as synchronization data or stored in Keychain. You can pause recording, exclude chosen apps, delete an item, or clear all history at any time. PEEK restores history to the system clipboard only when you request it. Copy and Paste uses Accessibility permission to send one `Command + V` to the app you were previously using. When you select a web-address item in the history panel, PEEK parses it locally and displays an offline link card without contacting the destination. The URL is handed to your external browser only after you choose Open in Browser.

### Screenshots, OCR, and QR codes

Screenshot pixels, annotations, OCR, and QR-code recognition are processed locally using macOS system capabilities. Results are copied to the system clipboard, saved to a location you choose, pinned on screen, or opened in another app only when you request that action. PEEK does not upload this content automatically.

If you choose to open a URL found in a QR code, macOS passes it to the appropriate browser. Any subsequent network activity is handled by the browser and destination website.

### Apple on-device translation

On supported macOS versions, Apple translation uses language models managed by the system. When you use only Apple on-device translation, PEEK does not send the text to Baidu, Google, or a PEEK-operated server. Language-pack downloads and management are handled by macOS and Apple. If you also enable cloud translation, the same text is sent to the applicable provider only when you actively submit a translation, as described in the next section.

## 3. Optional cloud translation

Baidu Translate and Google Translate are disabled by default. PEEK contacts a provider only after you supply your own credentials, enable that provider, and actively submit a translation. If both providers are enabled and fully configured, the same submission is sent to both.

### Baidu Translate

When enabled, PEEK sends the text, source and target languages, your Baidu APP ID, a random salt, and a locally generated signature directly to the Baidu Translate Open Platform over HTTPS. Your Baidu secret is stored in macOS Keychain and is used locally to generate the request signature; it is not sent as a plaintext request field.

### Google Translate

When enabled, PEEK sends the text, source language when specified, target language, and your Google Cloud Translation API key directly to Google Cloud Translation over HTTPS. The API key must be sent to Google with the request for authentication.

Cloud translation requests do not pass through a PEEK-operated server, and PEEK does not create a cloud translation history. The provider receives the text, credentials or signature needed to service the request, and ordinary network information. The provider may process or retain that data under its own terms and privacy policy. Before enabling a provider, review its policy and make sure you are authorized to send the text.

PEEK does not sell cloud-translation data or authorize providers to use it for advertising or cross-app tracking. A provider is used only to fulfill a translation request that you submit. If a provider materially changes its practices, PEEK will reassess the integration and update this policy or remove the feature.

## 4. API credentials

Baidu secrets and Google API keys are stored in macOS Keychain. The Baidu APP ID and provider switches are stored in PEEK's local preferences. PEEK does not send credentials to a PEEK-operated server or write them to diagnostic logs. When cloud translation is used, the authentication data required by the provider is sent directly as described above.

## 5. System permissions

PEEK requests the following permissions only when needed for a feature:

- **Files and folders:** Reads locations you explicitly authorize through the system file picker and builds a local index. Moving, copying, or saving files occurs only when you request it.
- **Screen Recording:** Reads screen pixels for region capture, scrolling capture, OCR capture, and related previews.
- **Accessibility / Post Event:** Identifies scrollable areas and sends scrolling events when you start scrolling capture. When you actively choose Copy and Paste, it sends one paste shortcut to the app you were previously using. It is not used to record keyboard input in the background.
- **Network access:** Used for Baidu or Google cloud translation that you enable and links you explicitly open in an external browser. Clipboard link cards do not use the network.
- **Clipboard:** Reads supported clipboard content locally while Clipboard History is enabled, and writes relevant content when you choose actions such as Paste, Copy, or completing a screenshot.

PEEK does not bypass protected windows, DRM content, files blocked by macOS, or the macOS privacy-permission database.

## 6. Retention, deletion, and withdrawal

- The local index and settings remain on your Mac so they can be used after the app restarts.
- Removing an authorized folder from PEEK Search settings stops it from participating in search, and related index records are removed by the local cleanup process.
- You can disable a cloud provider and delete its saved credentials in PEEK Settings. Remove credentials before uninstalling PEEK because macOS may preserve Keychain items after an app is removed.
- You can revoke Screen Recording, Accessibility, and file access at any time in **System Settings > Privacy & Security**.
- The current system clipboard is managed by macOS. You can pause recording, exclude apps, or clear PEEK's 100-item history in **Settings > Clipboard**. Cleared history cannot be recovered.
- PEEK does not retain cloud-translation text on a PEEK-operated server. Provider retention and deletion are governed by the provider's own policy; contact that provider to exercise applicable rights.
- To remove all local data, quit PEEK, delete saved cloud-translation credentials, and then remove PEEK and its macOS-managed app data.

## 7. Diagnostics

PEEK does not integrate third-party crash reporting or behavioral analytics services. The app and macOS may keep operational logs locally. PEEK's copyable diagnostics include the version, index status, and the local index database path with the account name abbreviated as `~`; they do not include document contents, screenshots, search terms, or API keys. You should still review anything before sharing it in a support request.

## 8. Children's privacy

PEEK does not target children for personal-data collection and does not include accounts, advertising, or tracking.

## 9. Changes to this policy

If PEEK materially changes how it handles data, this policy will be updated and the date above will change. Significant changes that affect user choices will also be communicated in the app or release notes.

## 10. Contact

For privacy, data-deletion, or product questions, use Support & Feedback in Settings. Issues on the support platform may be public by default. Remove file paths, screenshots, search terms, API credentials, and other sensitive information before posting.
