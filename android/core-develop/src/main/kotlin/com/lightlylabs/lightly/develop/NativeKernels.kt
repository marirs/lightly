package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.image.Rgba8Backing

/** Optional Android GLES compute pipeline. The JVM renderer remains the reference and unsupported-platform fallback. */
object NativeKernels {
    @Volatile private var loaded = false
    /** Enabled by Android only where HardwareBuffer-backed bitmaps can be displayed. */
    @Volatile var hardwareImages = false
    private class NativeBacking(override val platformHandle: Any, val width: Int, val height: Int, override val isOpaque: Boolean) : Rgba8Backing {
        override fun readPixels(): ByteArray = requireNotNull(readHardwareNative(platformHandle,width,height)) { "GPU preview readback failed" }
    }
    private fun hardwareImage(handle: Any, source: Rgba8Image) = Rgba8Image(source.width,source.height,NativeBacking(handle,source.width,source.height,source.isOpaque))
    private external fun readHardwareNative(handle: Any, width: Int, height: Int): ByteArray?

    private val reference = ThreadLocal.withInitial { false }
    // Only whole display proxies use this path; tiled full-resolution export keeps the CPU reference.
    fun canRender(width: Int, height: Int): Boolean = enabled && width.toLong() * height <= 1600L * 1600
    val enabled: Boolean get() = loaded && !reference.get()
    fun <T> reference(block: () -> T): T {
        val previous = reference.get()
        reference.set(true)
        return try { block() } finally { reference.set(previous) }
    }
    fun load(): Boolean {
        if (enabled) return true
        loaded = runCatching { System.loadLibrary("lightly_pixels") }.isSuccess
        return enabled
    }
    /** Internal-build diagnostic only: synchronously time the next Develop dispatch. */
    external fun profileNext()
    external fun gpuReady(): Boolean
    external fun lastUsedGpu(): Boolean
    // One bounded identity key. Native state is mutex-protected and verifies this generation before
    // reusing uploaded pixels; a thumbnail or another render lane therefore cannot reuse stale data.
    private class InputIdentity {
        private var cachedInputs = emptyList<Any?>()
        private var cachedShape = emptyList<Int>()
        private var generation = 0L
        @Synchronized
        fun generation(source: Any, width: Int, height: Int, params: DoubleArray,
            leak: ByteArray?, ink: ByteArray?): Long {
            val inputs = listOf(source, leak, ink)
            val shape=listOf(width,height,params.size,params[5].toInt(),params[6].toInt(),params[20].toInt(),params[21].toInt())
            if(shape!=cachedShape || inputs.size!=cachedInputs.size || inputs.indices.any { inputs[it] !== cachedInputs[it] }) {
                cachedInputs=inputs;cachedShape=shape;generation++
            }
            return generation
        }
    }
    // These stages own separate native buffers. Finishing a newly developed frame must
    // not evict the original photo's resident colour lookup cache on every slider update.
    private val finishInputs = InputIdentity()
    private val developInputs = InputIdentity()
    fun finish(image: Rgba8Image, params: DoubleArray, leak: ByteArray?, ink: ByteArray?, matrices: DoubleArray): Rgba8Image? {
        val width=image.width; val height=image.height
        val handle=(image.backing as? NativeBacking)?.platformHandle
        val key=handle ?: image.pixels
        val generation=finishInputs.generation(key,width,height,params,leak,ink)
        if(hardwareImages) {
            val result=finishHardwareNative(if(handle==null) image.pixels else null,handle,width,height,params,leak,ink,matrices,generation)
            if(result!=null) return hardwareImage(result,image)
            hardwareImages=false
        }
        return finishNative(image.pixels,width,height,params,leak,ink,matrices,generation)?.let { Rgba8Image(width,height,it) }
    }
    private external fun finishHardwareNative(source: ByteArray?, handle: Any?, width: Int, height: Int,
        params: DoubleArray, leak: ByteArray?, ink: ByteArray?, matrices: DoubleArray, generation: Long): Any?
    private external fun finishNative(source: ByteArray, width: Int, height: Int,
        params: DoubleArray, leak: ByteArray?, ink: ByteArray?, matrices: DoubleArray, generation: Long): ByteArray?
    fun develop(image: Rgba8Image,plan:DevelopRenderPlan,params:DoubleArray,matrices:DoubleArray,quantizeDevelop: Boolean = false, leak: ByteArray? = null, ink: ByteArray? = null): Rgba8Image? {
        val width=image.width; val height=image.height
        val model = plan.model
        val spatial = plan.spatial
        val n = maxOf(width, height)
        val scale = n / model.provisional.referenceLongEdgePx
        val nr = spatial.noiseReduction
        val sharp = spatial.sharpening
        val factor=Planes.lowResFactor(model.spatial.rClarity*n)
        val bw = (width + factor - 1) / factor
        val bh = (height + factor - 1) / factor
        val kernelSpecs=listOf(
            if(nr!=null && nr.luminance!=0.0) model.provisional.nrLumaRadiusPx*scale else null,
            if(nr!=null && nr.color!=0.0) model.provisional.nrColourRadiusPx*scale*(.5+nr.colorSmoothness/100) else null,
            if(spatial.texture!=0.0) model.spatial.rTexture*n else null,
            if(sharp!=null && sharp.amount!=0.0) sharp.radius*scale else null,
            if(spatial.clarity!=0.0) Planes.lowResSigma(model.spatial.rClarity*n,factor) else null)
        val kernels=kernelSpecs.mapIndexed { i,sigma -> if(sigma==null) DoubleArray(0) else Planes.kernel(sigma,if(i==4) maxOf(bw,bh) else n) }
        // ABI shared with gpu.cpp: 0..8 operation strengths, 9 downsample factor, 10..14
        // kernel sizes, 15..16 base dimensions, and Gaussian weights beginning at 24.
        val config=DoubleArray(24+kernels.sumOf { it.size })
        config[0]=model.provisional.nrDetailScale*(1.01-(nr?.luminanceDetail ?: 0.0)/100)
        config[1]=(nr?.luminance ?: 0.0)/100*(1-.5*(nr?.luminanceContrast ?: 0.0)/100)
        config[2]=(nr?.color ?: 0.0)/100
        config[3]=model.spatial.kClarity*spatial.clarity/100
        config[4]=model.spatial.kTexture*spatial.texture/100
        config[5]=(1-(sharp?.detail ?: 0.0)/100)*model.provisional.sharpenDetailThreshold
        config[6]=scale;config[7]=(sharp?.edgeMasking ?: 0.0)/100*model.provisional.sharpenEdgeScale
        config[8]=model.provisional.kSharpen*(sharp?.amount ?: 0.0)/100
        config[9]=factor.toDouble();config[15]=bw.toDouble();config[16]=bh.toDouble();config[17]=if(quantizeDevelop) 1.0 else 0.0
        var offset=24; kernels.forEachIndexed { i,k -> config[10+i]=k.size.toDouble();k.copyInto(config,offset);offset+=k.size }
        val handle=(image.backing as? NativeBacking)?.platformHandle
        val key=handle ?: image.pixels
        val generation=developInputs.generation(key,width,height,params,leak,ink)
        if(hardwareImages) {
            val result=developHardwareNative(if(handle==null) image.pixels else null,handle,width,height,
                plan.autoLut?.rgba,plan.autoLut?.dimension ?: 0,plan.unblendedLookLut?.rgba,plan.unblendedLookLut?.dimension ?: 0,
                plan.lookStrength,plan.hasSpatial,params,matrices,config,generation,leak,ink)
            if(result!=null)return hardwareImage(result,image)
            hardwareImages=false
        }
        return developNative(image.pixels,width,height,plan.autoLut?.rgba,plan.autoLut?.dimension ?: 0,plan.unblendedLookLut?.rgba,plan.unblendedLookLut?.dimension ?: 0,
            plan.lookStrength,plan.hasSpatial,params,matrices,config,generation,leak,ink)?.let { Rgba8Image(width,height,it) }
    }
    private external fun developHardwareNative(source:ByteArray?,handle:Any?,width:Int,height:Int,auto:FloatArray?,autoSize:Int,look:FloatArray?,lookSize:Int,
        strength:Float,lab:Boolean,params:DoubleArray,matrices:DoubleArray,spatial:DoubleArray,generation:Long,leak:ByteArray?,ink:ByteArray?):Any?
    private external fun developNative(source:ByteArray,width:Int,height:Int,auto:FloatArray?,autoSize:Int,look:FloatArray?,lookSize:Int,
        strength:Float,lab:Boolean,params:DoubleArray,matrices:DoubleArray,spatial:DoubleArray,generation:Long,leak:ByteArray?,ink:ByteArray?):ByteArray?
}
