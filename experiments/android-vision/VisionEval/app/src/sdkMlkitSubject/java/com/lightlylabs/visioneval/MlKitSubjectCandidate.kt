package com.lightlylabs.visioneval

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import com.google.android.gms.common.moduleinstall.InstallStatusListener
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.subject.SubjectSegmentation
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenter
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenterOptions
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * ML Kit Subject Segmentation (beta, UNBUNDLED). The model is a Google Play services optional
 * module downloaded at runtime by the Play services process. initialise() records whether the
 * module was already on the device and, if not, how the explicit ModuleInstallClient download
 * behaves (states, bytes, wall time). Inference itself runs inside the app process on-device.
 */
class MlKitSubjectCandidate : VisionCandidate {
    override val id = "mlkit_subject"
    override val kind = CandidateKind.SEGMENTATION
    override val sdkCoordinate = "com.google.android.gms:play-services-mlkit-subject-segmentation:16.0.0-beta1"
    override val modelDescription = "Google Play services optional module (runtime download)"
    private lateinit var segmenter: SubjectSegmenter

    override fun initialise(context: Context): JSONObject {
        segmenter = SubjectSegmentation.getClient(
            SubjectSegmenterOptions.Builder()
                .enableForegroundConfidenceMask()
                .enableMultipleSubjects(SubjectSegmenterOptions.SubjectResultOptions.Builder().enableConfidenceMask().build())
                .build()
        )
        val details = JSONObject()
        val moduleInstallClient = ModuleInstall.getClient(context)
        val availabilityStart = SystemClock.elapsedRealtimeNanos()
        val availableBefore = Tasks.await(moduleInstallClient.areModulesAvailable(segmenter), 30, TimeUnit.SECONDS)
            .areModulesAvailable()
        details.put("module_available_before", availableBefore)
            .put("availability_check_ms", EvalRunner.elapsedMs(availabilityStart))
        if (!availableBefore) details.put("download", downloadModule(moduleInstallClient))
        return details
    }

    private fun downloadModule(moduleInstallClient: com.google.android.gms.common.moduleinstall.ModuleInstallClient): JSONObject {
        val download = JSONObject()
        val states = JSONArray()
        val finished = CountDownLatch(1)
        val listenerExecutor = Executors.newSingleThreadExecutor()
        val start = SystemClock.elapsedRealtimeNanos()
        val listener = InstallStatusListener { update ->
            val progress = update.progressInfo
            states.put(
                JSONObject().put("t_ms", EvalRunner.elapsedMs(start)).put("state", update.installState)
                    .put("bytes", progress?.bytesDownloaded ?: JSONObject.NULL)
                    .put("total_bytes", progress?.totalBytesToDownload ?: JSONObject.NULL)
                    .put("error", update.errorCode)
            )
            if (update.installState in TERMINAL_STATES) finished.countDown()
        }
        val request = ModuleInstallRequest.newBuilder().addApi(segmenter).setListener(listener, listenerExecutor).build()
        val response = Tasks.await(moduleInstallClient.installModules(request), 60, TimeUnit.SECONDS)
        download.put("already_installed", response.areModulesAlreadyInstalled())
        if (!response.areModulesAlreadyInstalled()) {
            download.put("completed_in_time", finished.await(DOWNLOAD_TIMEOUT_S, TimeUnit.SECONDS))
        }
        download.put("wall_ms", EvalRunner.elapsedMs(start)).put("states", states)
        moduleInstallClient.unregisterListener(listener)
        listenerExecutor.shutdown()
        return download
    }

    override fun analyse(photo: Bitmap): CandidateOutput {
        val result = Tasks.await(segmenter.process(InputImage.fromBitmap(photo, 0)))
        val width = photo.width
        val height = photo.height
        val masks = LinkedHashMap<String, ConfidenceMask>()
        result.foregroundConfidenceMask?.let { masks["foreground"] = ConfidenceMask.fromFloatBuffer(width, height, it) }
        val subjectsJson = JSONArray()
        var largestArea = 0
        for ((subjectIndex, subject) in result.subjects.withIndex()) {
            subjectsJson.put(
                JSONObject().put("box", JsonGeometry.box(
                    subject.startX.toFloat() / width, subject.startY.toFloat() / height,
                    subject.width.toFloat() / width, subject.height.toFloat() / height,
                ))
            )
            val area = subject.width * subject.height
            val subjectMask = subject.confidenceMask ?: continue
            val fullFrame = placeInFullFrame(subjectMask, subject.startX, subject.startY, subject.width, subject.height, width, height)
            // Instances are kept individually (capped) so multi-person photos show whether each
            // person is separated or merged; the largest one is the auto "main subject" proxy.
            if (subjectIndex < MAX_SAVED_SUBJECTS) masks["subject_$subjectIndex"] = fullFrame
            if (area > largestArea) {
                largestArea = area
                masks["subject_largest"] = fullFrame
            }
        }
        return CandidateOutput(JSONObject().put("subjects", subjectsJson).put("subject_count", result.subjects.size), masks)
    }

    /** Subject masks cover only the subject's box; expand to full-frame for uniform comparison. */
    private fun placeInFullFrame(
        buffer: java.nio.FloatBuffer, startX: Int, startY: Int, boxWidth: Int, boxHeight: Int,
        frameWidth: Int, frameHeight: Int,
    ): ConfidenceMask {
        val boxValues = FloatArray(boxWidth * boxHeight)
        buffer.rewind()
        buffer.get(boxValues)
        val frame = FloatArray(frameWidth * frameHeight)
        for (y in 0 until boxHeight) {
            val frameY = startY + y
            if (frameY !in 0 until frameHeight) continue
            for (x in 0 until boxWidth) {
                val frameX = startX + x
                if (frameX in 0 until frameWidth) frame[frameY * frameWidth + frameX] = boxValues[y * boxWidth + x]
            }
        }
        return ConfidenceMask(frameWidth, frameHeight, frame)
    }

    override fun close() = segmenter.close()

    companion object {
        private const val DOWNLOAD_TIMEOUT_S = 300L
        private const val MAX_SAVED_SUBJECTS = 6
        private val TERMINAL_STATES = setOf(
            ModuleInstallStatusUpdate.InstallState.STATE_COMPLETED,
            ModuleInstallStatusUpdate.InstallState.STATE_FAILED,
            ModuleInstallStatusUpdate.InstallState.STATE_CANCELED,
        )

        fun all(): List<VisionCandidate> = listOf(MlKitSubjectCandidate())
    }
}
