package com.ygkim.book_scan

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * 백업·복원용 메서드 채널 'bookscan/backup'.
 *  - freeSpace(path): 그 경로가 있는 저장소의 남은 바이트
 *  - saveFile(path, name): 저장 창(ACTION_CREATE_DOCUMENT)으로 위치를 고르게 하고 임시 파일을 조금씩 복사
 *  - openFile(destDir): 파일 고르기 창(ACTION_OPEN_DOCUMENT)으로 고른 파일을 destDir/import.zip 으로 조금씩 복사
 * 결과는 {status: saved|ok|cancel|error, message?, path?, size?}. 파일 전체를 메모리에 올리지 않는다.
 */
class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingArg: String? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bookscan/backup")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "freeSpace" -> {
                        try {
                            val p = call.argument<String>("path") ?: filesDir.path
                            result.success(StatFs(p).availableBytes)
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    "saveFile" -> {
                        val path = call.argument<String>("path")
                        val name = call.argument<String>("name") ?: "backup.zip"
                        if (path == null || !File(path).exists()) {
                            result.success(fail("저장할 백업 파일을 찾지 못했습니다."))
                        } else if (pending != null) {
                            result.success(fail("다른 저장 작업이 진행 중입니다. 잠시 뒤에 다시 해 주세요."))
                        } else {
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/zip"
                                putExtra(Intent.EXTRA_TITLE, name)
                            }
                            launch(intent, REQ_SAVE, path, result)
                        }
                    }
                    "openFile" -> {
                        val dir = call.argument<String>("destDir")
                        if (dir == null) {
                            result.success(fail("가져올 위치를 정하지 못했습니다."))
                        } else if (pending != null) {
                            result.success(fail("다른 작업이 진행 중입니다. 잠시 뒤에 다시 해 주세요."))
                        } else {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                putExtra(
                                    Intent.EXTRA_MIME_TYPES,
                                    arrayOf("application/zip", "application/x-zip-compressed", "application/octet-stream")
                                )
                            }
                            launch(intent, REQ_OPEN, dir, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun fail(msg: String): Map<String, Any?> = mapOf("status" to "error", "message" to msg)

    private fun launch(intent: Intent, code: Int, arg: String, result: MethodChannel.Result) {
        pending = result
        pendingArg = arg
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, code)
        } catch (e: Exception) {
            complete(fail("파일 선택 창을 열지 못했습니다."))
        }
    }

    private fun complete(map: Map<String, Any?>) {
        val r = pending
        pending = null
        pendingArg = null
        r?.success(map)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQ_SAVE && requestCode != REQ_OPEN) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val uri: Uri? = data?.data
        val arg = pendingArg
        if (resultCode != Activity.RESULT_OK || uri == null || arg == null) {
            complete(mapOf("status" to "cancel"))
            return
        }
        // 큰 파일일 수 있으니 화면을 막지 않도록 다른 스레드에서 복사한다.
        Thread {
            val out: Map<String, Any?> = try {
                if (requestCode == REQ_SAVE) saveTo(uri, arg) else openFrom(uri, arg)
            } catch (e: Exception) {
                if (requestCode == REQ_SAVE) {
                    try { DocumentsContract.deleteDocument(contentResolver, uri) } catch (_: Exception) {}
                    fail("저장하지 못했습니다. 저장 공간이 부족하거나 그 위치에 쓸 수 없습니다.")
                } else {
                    fail("파일을 읽지 못했습니다. 저장 공간이 부족하거나 파일이 없어졌을 수 있습니다.")
                }
            }
            main.post { complete(out) }
        }.start()
    }

    private fun saveTo(uri: Uri, path: String): Map<String, Any?> {
        val src = File(path)
        val os = contentResolver.openOutputStream(uri, "wt")
            ?: return fail("그 위치에 쓸 수 없습니다. 다른 위치를 골라 주세요.")
        var total = 0L
        os.use { o ->
            FileInputStream(src).use { i ->
                val buf = ByteArray(1 shl 20)
                while (true) {
                    val n = i.read(buf)
                    if (n < 0) break
                    o.write(buf, 0, n)
                    total += n
                }
                o.flush()
            }
        }
        if (total != src.length()) throw RuntimeException("size mismatch")
        return mapOf("status" to "saved", "size" to total)
    }

    private fun openFrom(uri: Uri, destDir: String): Map<String, Any?> {
        val dir = File(destDir)
        dir.mkdirs()
        val dest = File(dir, "import.zip")
        if (dest.exists()) dest.delete()
        val ins = contentResolver.openInputStream(uri) ?: return fail("그 파일을 열 수 없습니다.")
        var total = 0L
        try {
            ins.use { i ->
                FileOutputStream(dest).use { o ->
                    val buf = ByteArray(1 shl 20)
                    while (true) {
                        val n = i.read(buf)
                        if (n < 0) break
                        o.write(buf, 0, n)
                        total += n
                    }
                    o.flush()
                }
            }
        } catch (e: Exception) {
            dest.delete()
            throw e
        }
        return mapOf("status" to "ok", "path" to dest.path, "size" to total)
    }

    companion object {
        private const val REQ_SAVE = 7101
        private const val REQ_OPEN = 7102
    }
}
