import CoreImage.CIFilterBuiltins
import SwiftUI

struct PairingQRCode: View {
    let host: String
    let token: String

    private var image: UIImage? {
        guard let value = PairingPayload(host: host, token: token).qrValue else { return nil }
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(value.utf8)
        generator.correctionLevel = "M"
        guard let output = generator.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var body: some View {
        if let image {
            HStack(alignment: .center, spacing: 16) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 176, height: 176)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("ComputeBridge pairing QR code")
                Text("On your Mac, choose Scan QR and point its camera at this code.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else {
            Text("Connect this iPhone to Wi-Fi to create a pairing QR code.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}
