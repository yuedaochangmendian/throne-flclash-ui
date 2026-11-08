package io.flrone.flutter

import android.content.Intent
import com.google.zxing.Result
import com.king.zxing.CameraScan
import com.king.zxing.CaptureActivity
import io.flrone.bridge.BboxScanChunks

/**
 * The QR scan screen, hosted by Throne instead of by a Flutter plugin.
 *
 * ZXingLite's [CaptureActivity] already owns the CameraX preview, the viewfinder and ZXing's
 * decoder. This subclass only decides when the payload is complete and hands it back to
 * [BboxFlutterActivity]: returning true from the callback keeps the camera running, so a QR too
 * large for one symbol can arrive as several frames. [BboxScanChunks] is the same assembler the
 * old frame-by-frame Dart path fed, so multi-frame imports keep their behaviour.
 */
class BboxQrScanActivity : CaptureActivity() {

    private val chunks = BboxScanChunks()

    override fun onScanResultCallback(result: Result): Boolean {
        val decision = chunks.accept(SESSION, result.text.orEmpty())
        if (decision.complete && decision.text.isNotEmpty()) {
            setResult(RESULT_OK, Intent().putExtra(CameraScan.SCAN_RESULT, decision.text))
            finish()
        }
        // true: never let the library end the activity after the first decoded frame.
        return true
    }

    private companion object {
        const val SESSION = "qr-scan"
    }
}
