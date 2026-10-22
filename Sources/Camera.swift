import SwiftUI
import Photos

// System camera (UIImagePickerController); SwiftUI has no camera view of its own.
struct CameraPicker: UIViewControllerRepresentable {
    let onShot: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    // Add-only access (NSPhotoLibraryAddUsageDescription): the app can save shots but can't read the library.
    static func saveToLibrary(_ image: UIImage) async {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let shot = info[.originalImage] as? UIImage { parent.onShot(shot) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
