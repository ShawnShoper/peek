# PEEK App Review Notes

PEEK is a macOS menu-bar utility (`LSUIElement`). After launch, click the PEEK
icon in the macOS menu bar. Every user-facing feature is listed there, including
File Search, Translation, Clipboard History, Region Capture, Scrolling Capture,
OCR Capture, Settings, and the complete Feature Overview.

PEEK does not contain reviewer-specific, account-specific, geographic,
time-based, or remotely activated feature gates. It does not download executable
code or alter functionality for App Review. The Feature Overview is shown once
for every shipped build to both new and existing users and can always be replayed
from the menu.

## Review steps

1. Launch PEEK. The Feature Overview opens automatically once for build 4.
2. Complete or skip the overview, then click the PEEK icon in the menu bar.
3. Choose **File Search** and type an installed application name. Press Return to
   launch the selected application.
4. Choose **Translation**. Apple on-device translation requires macOS 15 or later
   and installed system language models. Baidu and Google are optional providers
   that require the user's own credentials; they are not needed to review the
   rest of the app.
5. Choose **Clipboard History**. Recording is disabled by default for privacy and
   is visibly marked as disabled. Enable it in **Settings > Clipboard**.
6. Choose **Region Capture** or **OCR Capture**. macOS Screen Recording permission
   is required because these functions read pixels selected by the user.
7. Choose **Scrolling Capture**. Accessibility permission is requested only when
   the user selects automatic scrolling; manual scrolling remains available.
8. Open **Settings** to review every feature category, permission explanation,
   local-storage boundary, and the bundled Privacy Policy.

File indexing, screenshots, OCR, QR recognition, and Apple translation are
processed locally. Optional cloud translation is disabled by default and sends
text only after the user configures a provider and explicitly submits a request.
PEEK has no proprietary server and no remote configuration service.
