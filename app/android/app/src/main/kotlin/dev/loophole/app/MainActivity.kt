package dev.loophole.app

import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.reactivex.exceptions.UndeliverableException
import io.reactivex.plugins.RxJavaPlugins

// FlutterFragmentActivity: Health Connect's permission request needs registerForActivityResult.
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The BLE plugin (RxAndroidBle) reports a late disconnect after its stream is already closed. Without a
        // handler RxJava rethrows it and kills the app; the Dart side already reconnects, so just log it.
        RxJavaPlugins.setErrorHandler { e ->
            if (e is UndeliverableException) Log.w("Loophole", "late BLE error ignored: ${e.cause?.javaClass?.simpleName}") // the message can hold the address
            else Thread.currentThread().uncaughtExceptionHandler?.uncaughtException(Thread.currentThread(), e)
        }
    }
}
