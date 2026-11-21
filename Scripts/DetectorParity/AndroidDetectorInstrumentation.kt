package dev.sawitulm.palmannotate.data.detection

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle

class AndroidDetectorInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        try {
            DetectorProbe.run(context) { row ->
                sendStatus(0, Bundle().apply { putString("palm", row) })
            }
            finish(Activity.RESULT_OK, Bundle())
        } catch (error: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply {
                putString("error", error.stackTraceToString())
            })
        }
    }
}
