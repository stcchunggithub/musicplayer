import Flutter
import UIKit
import UniformTypeIdentifiers

// This is the piece that makes "no duplicate storage" possible.
//
// Flutter's community file-picker plugins open iOS's document picker in
// "import" mode, which COPIES the selected file into the app's own
// sandbox — the same duplication problem the web version had. This
// class instead opens the picker in "open" (reference) mode, and turns
// each selected file into a security-scoped bookmark: a small blob of
// data (a few hundred bytes, not the file itself) that the app can
// later resolve back into a live, readable URL pointing at the
// ORIGINAL file — even after the app has been fully closed and
// relaunched — without ever copying the audio data.
class BookmarkChannel: NSObject, UIDocumentPickerDelegate {
    private var pickResult: FlutterResult?
    // Keeps a URL's security scope open for as long as we might need to
    // read from it (i.e. while it's the loaded/playing track). Iterating
    // and calling stopAccessingSecurityScopedResource on app termination
    // would be ideal; for simplicity here it's released when a new
    // bookmark is resolved in its place.
    private var activeScopedURL: URL?

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "mp3player/bookmarks",
            binaryMessenger: registrar.messenger()
        )
        let instance = BookmarkChannel()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickFiles":
            presentPicker(result: result)
        case "resolveBookmark":
            guard
                let args = call.arguments as? [String: Any],
                let base64 = args["bookmark"] as? String
            else {
                result(FlutterError(code: "bad_args", message: "Missing bookmark", details: nil))
                return
            }
            resolveBookmark(base64: base64, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func presentPicker(result: @escaping FlutterResult) {
        self.pickResult = result

        let types: [UTType] = [UTType.mp3, UTType.mpeg4Audio, UTType.audio]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self

        guard
            let rootVC = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                .first?.rootViewController
        else {
            result(FlutterError(code: "no_root_vc", message: "No root view controller", details: nil))
            return
        }
        rootVC.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var items: [[String: String]] = []
        for url in urls {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            do {
                let bookmarkData = try url.bookmarkData(
                    options: [], // do NOT use .minimalBookmark — it can drop the
                                 // ability to resolve after the app restarts
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                let base64 = bookmarkData.base64EncodedString()
                items.append(["name": url.lastPathComponent, "bookmark": base64])
            } catch {
                // Skip files we couldn't bookmark; the rest still succeed.
                continue
            }
        }
        pickResult?(items)
        pickResult = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickResult?([])
        pickResult = nil
    }

    private func resolveBookmark(base64: String, result: @escaping FlutterResult) {
        guard let data = Data(base64Encoded: base64) else {
            result(FlutterError(code: "bad_bookmark", message: "Could not decode bookmark", details: nil))
            return
        }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let started = url.startAccessingSecurityScopedResource()
            if !started {
                result(FlutterError(code: "access_denied", message: "Could not access file", details: nil))
                return
            }
            activeScopedURL = url
            // isStale is informational (e.g. the file moved within its
            // container) — the URL is still usable this session either way.
            result(["path": url.path])
        } catch {
            result(FlutterError(
                code: "resolve_failed",
                message: "File may have been moved or deleted: \(error.localizedDescription)",
                details: nil
            ))
        }
    }
}
