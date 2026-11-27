package io.github.ss44.saathi

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var replyNotifications: ReplyNotifications? = null
    private var sharedText: SharedTextInbox? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        val share = intent?.takeIf { it.action == Intent.ACTION_SEND }
        // Keep share extras and URIs out of Flutter deep-link routing and task restoration.
        if (share != null) setIntent(Intent(Intent.ACTION_MAIN))
        super.onCreate(savedInstanceState)
        if (share != null && savedInstanceState == null) acceptShare(share)
    }

    private fun acceptShare(intent: Intent) {
        val inbox = sharedText ?: return
        if (!inbox.accept(intent)) {
            Toast.makeText(this, R.string.share_text_unavailable, Toast.LENGTH_LONG).show()
        }
    }

    override fun onStart() { super.onStart(); replyNotifications?.background = false }
    override fun onStop() { replyNotifications?.background = true; super.onStop() }
    override fun onNewIntent(intent: Intent) {
        if (intent.action == Intent.ACTION_SEND) {
            super.onNewIntent(Intent(Intent.ACTION_MAIN))
            acceptShare(intent)
            return
        }
        super.onNewIntent(intent)
        setIntent(intent)
        replyNotifications?.accept(intent)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 731) replyNotifications?.permissionResult()
    }
    override fun onDestroy() { replyNotifications?.dispose(); replyNotifications = null; super.onDestroy() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sharedText = SharedTextInbox(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saathi/shared_text"))
        replyNotifications = ReplyNotifications(this,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saathi/notifications"))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saathi/updates")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getCacheDirectory" -> {
                            val directory = File(cacheDir, "updates").canonicalFile
                            check(directory.mkdirs() || directory.isDirectory)
                            result.success(directory.path)
                        }
                        "installApk" -> {
                            val path = call.argument<String>("path")
                                ?: throw IllegalArgumentException("Missing APK path")
                            val expectedBuild = call.argument<Number>("expectedBuild")?.toLong()
                                ?: throw IllegalArgumentException("Missing expected build")
                            val expectedVersion = call.argument<String>("expectedVersion")
                                ?: throw IllegalArgumentException("Missing expected version")
                            installApk(path, expectedBuild, expectedVersion)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: InstallPermissionRequired) {
                    result.error("install_permission_required", "Allow Saathi to install updates, then retry.", null)
                } catch (error: Exception) {
                    // Never include the downloaded filename, remote URL or credentials.
                    result.error("update_install_failed", "The update could not be verified or opened.", null)
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        sharedText?.dispose()
        sharedText = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    @Suppress("DEPRECATION")
    private fun installApk(path: String, expectedBuild: Long, expectedVersion: String) {
        val directory = File(cacheDir, "updates").canonicalFile
        val apk = File(path).canonicalFile
        require(apk.parentFile == directory && apk.isFile && apk.extension == "apk")
        require(apk.length() in 1..536870912L)
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val candidate = packageManager.getPackageArchiveInfo(apk.path, flags)
            ?: throw IllegalArgumentException("Invalid package archive")
        val current = packageManager.getPackageInfo(packageName, flags)
        require(candidate.packageName == packageName)
        require(versionCode(candidate) > versionCode(current))
        require(versionCode(candidate) == expectedBuild)
        require(candidate.versionName == expectedVersion)
        require(signaturesMatch(candidate, current))
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            throw InstallPermissionRequired()
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signaturesMatch(candidate: PackageInfo, current: PackageInfo): Boolean {
        // Require the same current signer set; rotated keys deliberately fail closed
        // until a release policy for certificate lineage has been tested on devices.
        fun fingerprints(info: PackageInfo): Set<String> {
            val signatures = if (Build.VERSION.SDK_INT >= 28) {
                info.signingInfo?.apkContentsSigners
            } else {
                info.signatures
            }
            return signatures?.map { signature ->
                MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                    .joinToString("") { "%02x".format(it) }
            }?.toSet() ?: emptySet()
        }
        val actual = fingerprints(current)
        return actual.isNotEmpty() && actual == fingerprints(candidate)
    }

    private class InstallPermissionRequired : Exception()
}
