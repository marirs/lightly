package com.lightlylabs.lutbench

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtLoggingLevel
import ai.onnxruntime.OrtSession
import ai.onnxruntime.providers.NNAPIFlags
import org.json.JSONObject
import java.io.File
import java.nio.FloatBuffer
import java.util.EnumSet

/**
 * ONNX Runtime classifier benchmark across execution providers.
 *
 * Cold load = the first createSession for that EP in this process (env already exists; env
 * creation, which includes loading libonnxruntime.so, is reported separately as env_create_s).
 * Warm load = median of WARM_LOAD_REPEATS further createSession calls for the same EP.
 */
class OrtBench(private val modelFile: File, private val log: (String) -> Unit) {
    lateinit var environment: OrtEnvironment
        private set
    var environmentCreateSeconds: Double = Double.NaN
        private set

    /** Open sessions keyed by EP name, kept for the per-image inference runs. */
    val sessions = LinkedHashMap<String, OrtSession>()

    fun createEnvironment(loggingLevel: OrtLoggingLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_WARNING) {
        val (env, ms) = timedMs { OrtEnvironment.getEnvironment(loggingLevel, "lutbench") }
        environment = env
        environmentCreateSeconds = ms / 1000.0
    }

    fun sessionOptionsFor(ep: String): OrtSession.SessionOptions {
        val options = OrtSession.SessionOptions()
        when (ep) {
            "cpu" -> Unit
            "xnnpack" -> {
                // ORT guidance for XNNPACK: give the threads to XNNPACK's pool and keep the ORT
                // intra-op pool at 1 so the two pools do not contend for cores.
                options.setIntraOpNumThreads(1)
                options.addConfigEntry("session.intra_op.allow_spinning", "0")
                options.addXnnpack(mapOf("intra_op_num_threads" to XNNPACK_THREADS.toString()))
            }
            "nnapi" -> options.addNnapi()
            // CPU_DISABLED removes NNAPI's own reference-CPU device so NNAPI must use an
            // accelerator; nodes NNAPI cannot take still fall back to ORT's CPU EP.
            "nnapi_cpu_disabled" -> options.addNnapi(EnumSet.of(NNAPIFlags.CPU_DISABLED))
            else -> throw IllegalArgumentException("unknown EP $ep")
        }
        return options
    }

    /** Returns the JSON "model" entry for one EP and keeps a session open on success. */
    fun loadExecutionProvider(ep: String): JSONObject {
        val entry = JSONObject()
            .put("bytes", modelFile.length())
            .put("load_cold_s", JSONObject.NULL)
            .put("load_warm_s", JSONObject.NULL)
            .put("error", JSONObject.NULL)
        try {
            val (coldSession, coldMs) = timedMs {
                environment.createSession(modelFile.absolutePath, sessionOptionsFor(ep))
            }
            entry.put("load_cold_s", coldMs / 1000.0)
            val warmTimes = ArrayList<Double>()
            var lastSession = coldSession
            repeat(WARM_LOAD_REPEATS) {
                val (session, ms) = timedMs {
                    environment.createSession(modelFile.absolutePath, sessionOptionsFor(ep))
                }
                warmTimes.add(ms / 1000.0)
                lastSession.close()
                lastSession = session
            }
            entry.put("load_warm_s", median(warmTimes))
            entry.put("load_warm_all_s", org.json.JSONArray(warmTimes))
            sessions[ep] = lastSession
            log("ORT $ep: cold ${"%.3f".format(coldMs / 1000)} s, warm ${"%.3f".format(median(warmTimes))} s")
        } catch (throwable: Throwable) {
            entry.put("error", "${throwable.javaClass.name}: ${throwable.message}")
            log("ORT $ep load FAILED: ${throwable.javaClass.name}: ${throwable.message}")
        }
        return entry
    }

    fun infer(session: OrtSession, tensor: OnnxTensor): FloatArray {
        session.run(mapOf(INPUT_NAME to tensor)).use { result ->
            @Suppress("UNCHECKED_CAST")
            val output = result[0].value as Array<FloatArray>
            return output[0].copyOf()
        }
    }

    fun createInputTensor(chw: FloatArray): OnnxTensor =
        OnnxTensor.createTensor(environment, FloatBuffer.wrap(chw), longArrayOf(1, 3, 256, 256))

    fun closeAll() {
        sessions.values.forEach { runCatching { it.close() } }
        sessions.clear()
    }

    companion object {
        const val INPUT_NAME = "image"
        const val WARM_LOAD_REPEATS = 3
        const val XNNPACK_THREADS = 4
        val EXECUTION_PROVIDERS = listOf("cpu", "xnnpack", "nnapi", "nnapi_cpu_disabled")
    }
}
