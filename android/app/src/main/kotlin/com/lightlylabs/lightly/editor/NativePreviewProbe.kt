package com.lightlylabs.lightly.editor

import android.util.Log
import com.lightlylabs.lightly.develop.*
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.Lut3D
import kotlinx.serialization.json.JsonObject
import java.util.concurrent.Executors
import kotlin.math.abs

/** Explicit opt-in on internal builds only; never part of an ordinary edit or release launch. */
internal object NativePreviewProbe {
    fun run(context: android.content.Context, library: DevelopLibrary, catalogueStart: Int = 0, catalogueCount: Int = 0) {
        val model = library.model
        val pool=Executors.newFixedThreadPool(6)
        try {
            check(NativeKernels.enabled && NativeKernels.gpuReady()) { "GPU pipeline unavailable" }
            val renderer=DevelopRenderer(pool,6)
            val w=1600; val h=1067
            val input=Rgba8Image(w,h,kotlin.random.Random(42).nextBytes(w*h*4))
            var checked=0
            fun checkPixels(label:String, expected:ByteArray, actual:ByteArray) {
                check(NativeKernels.lastUsedGpu()) { "$label fell back to CPU" }
                var error=0; var changed=0
                for(i in expected.indices) {val d=abs((expected[i].toInt() and 255)-(actual[i].toInt() and 255));error=maxOf(error,d);if(d>0)changed++;if(i%4==3)check(d==0){"$label alpha at $i expected=${expected[i].toInt() and 255} actual=${actual[i].toInt() and 255}"}}
                check(error<=1){"$label error=$error"}; checked++
                Log.i("LightlyNative","PARITY $label max=$error changed=$changed/${actual.size}")
            }
            // Start with a hardware source before any CPU finishing input has allocated
            // its packed buffer. Preset removal/identity switches take this path in the editor.
            val transitionSource=Rgba8Image(127,93,kotlin.random.Random(194).nextBytes(127*93*4))
            val transitionPreset=requireNotNull(library.pack.preset("look-ce85dea9dbeff5240603"))
            val transitionPlan=DevelopRenderPlan.of(model,null,0f,library.lutFor(transitionPreset),transitionPreset.recipe,.85f)
            val hardwareSource=renderer.render(transitionSource,transitionPlan)
            check(hardwareSource.backing!=null) { "Transition setup must produce hardware pixels" }
            val transitionEffects=EffectsStage(EffectsParams(grainEnabled=true,grainAmount=20.0,grainSeed=42),FinishingRecipe.NEUTRAL,model,127,93)
            for((label,source) in listOf("hardware" to hardwareSource,"cpu" to transitionSource,"hardware again" to hardwareSource)) {
                val expected=NativeKernels.reference { transitionEffects.apply(source,renderer=renderer) }
                val actual=transitionEffects.apply(source,renderer=renderer)
                check(NativeKernels.hardwareImages && actual.backing!=null) { "$label source disabled hardware preview" }
                checkPixels("source storage transition $label",expected.pixels,actual.pixels)
            }
            for(style in listOf("warm","amber","rose","prism","leak-000000000001")) {
                val e=EffectsParams(leakEnabled=true,leakStyle=style,leakRotation=54.0,leakImage=Rgba8Image(31,29,ByteArray(31*29*4){(it*17).toByte()}),
                    grainEnabled=true,grainAmount=80.0,grainSeed=42,vignetteEnabled=true,vignetteAmount=60.0,
                    selectiveColours=listOf(KeptColour(.5,.1,.1)))
                val stage=EffectsStage(e,FinishingRecipe.NEUTRAL,model,w,h)
                val expected=NativeKernels.reference{stage.apply(input,renderer=renderer)}
                checkPixels(style,expected.pixels,stage.apply(input,renderer=renderer).pixels)
                val times=(1..5).map { val start=System.nanoTime();stage.apply(input,renderer=renderer);(System.nanoTime()-start)/1e6 }
                Log.i("LightlyNative","TIMING $style ${times.sorted()}")
            }
            for(style in 1..3) {
                val stage = EffectsStage(EffectsParams(grainEnabled=true,grainAmount=75.0,grainSeed=123,
                    vignetteEnabled=true,vignetteAmount=65.0),
                    FinishingRecipe(Vignette(-45.0,40.0,60.0,20.0,style,30.0),Grain(60.0,30.0,45.0,42)),model,w,h)
                val expected=NativeKernels.reference { stage.apply(input,renderer=renderer) }
                checkPixels("combined finishing $style",expected.pixels,stage.apply(input,renderer=renderer).pixels)
            }
            // Exercise cache misses while dragging grain geometry, including supersampled fine grain.
            for(size in listOf(0.0,25.0,60.0,100.0)) for(roughness in listOf(0.0,50.0,100.0)) {
                val effects=EffectsStage(EffectsParams(grainEnabled=true,grainAmount=80.0,
                    grainSize=size,grainRoughness=roughness,grainSeed=0xfedcba98L),
                    FinishingRecipe.NEUTRAL,model,w,h)
                val expected=NativeKernels.reference { effects.apply(input,renderer=renderer) }
                val start=System.nanoTime()
                val actual=effects.apply(input,renderer=renderer)
                val millis=(System.nanoTime()-start)/1e6
                checkPixels("grain geometry $size $roughness",expected.pixels,actual.pixels)
                Log.i("LightlyNative","GEOMETRY size=$size roughness=$roughness ${millis}ms")
            }
            // A changing Develop result must reuse only geometry fields, never old pixels.
            val repeatedEffects = EffectsStage(EffectsParams(grainEnabled=true, grainSeed=42,
                vignetteEnabled=true), FinishingRecipe.NEUTRAL, model, 127, 93)
            for(seed in 1..4) {
                val changed = Rgba8Image(127,93,kotlin.random.Random(seed).nextBytes(127*93*4))
                val expected = NativeKernels.reference { repeatedEffects.apply(changed,renderer=renderer) }
                checkPixels("changing source $seed",expected.pixels,repeatedEffects.apply(changed,renderer=renderer).pixels)
            }
            // Fused presets must retain every effect, including asset overlays and changing
            // selective-colour counts, when the same original source stays resident.
            for(style in listOf("warm", "rose", "leak-000000000001")) for(count in 0..2) {
                val e=EffectsParams(leakEnabled=true,leakStyle=style,leakRotation=54.0,
                    leakImage=Rgba8Image(31,29,kotlin.random.Random(17).nextBytes(31*29*4)),
                    grainEnabled=true,grainAmount=40.0,grainSeed=42,vignetteEnabled=true,vignetteAmount=35.0,
                    selectiveColours=listOf(KeptColour(.5,.1,.1),KeptColour(.6,-.1,.03)).take(count),
                    ink=if(count==2) InkParams(InkKind.STROKE,GreyImage(31,29,kotlin.random.Random(19).nextBytes(31*29)),size=65.0,rotation=33.0) else null)
                val stage=EffectsStage(e,transitionPlan.finishing,model,127,93)
                val plan=transitionPlan.withoutFinishing()
                val separate=stage.apply(renderer.render(transitionSource,plan),renderer=renderer)
                val fused=requireNotNull(stage.applyAfterDevelop(transitionSource,renderer,plan))
                check(fused.backing!=null && NativeKernels.hardwareImages)
                checkPixels("fused overlays $style $count",separate.pixels,fused.pixels)
            }
            val auto=Lut3D.identity();val look=Lut3D.identity()
            for(i in auto.rgba.indices step 4) {
                val r=auto.rgba[i];val g=auto.rgba[i+1];val b=auto.rgba[i+2]
                auto.rgba[i]=r*.8f+g*.1f+.04f;auto.rgba[i+1]=g*.87f+b*.06f;auto.rgba[i+2]=b*.9f+r*.05f
                look.rgba[i]=r*.9f+.06f;look.rgba[i+1]=g*.85f+r*.05f;look.rgba[i+2]=b*.8f+g*.1f
            }
            for(style in listOf(1,2,3)) {
                val recipe=PresetRecipe(GlobalRecipe.NEUTRAL,SpatialRecipe(NoiseReduction(60.0,40.0,20.0,50.0,50.0,60.0),45.0,30.0,Sharpening(80.0,1.2,30.0,40.0)),
                    FinishingRecipe(Vignette(-35.0,40.0,60.0,20.0,style,30.0),Grain(40.0,30.0,45.0,42)),JsonObject(emptyMap()))
                val plan=DevelopRenderPlan.of(model,auto,.5f,look,recipe,.7f)
                val expected=NativeKernels.reference{renderer.render(input,plan)}
                checkPixels("spatial$style",expected.pixels,renderer.render(input,plan).pixels)
                val times=(1..5).map { if(style==1 && it==1)NativeKernels.profileNext(); val start=System.nanoTime();renderer.render(input,plan);(System.nanoTime()-start)/1e6 }
                Log.i("LightlyNative","TIMING spatial$style ${times.sorted()}")
                val effects=EffectsStage(EffectsParams(grainEnabled=true,grainAmount=65.0,grainSeed=123,
                    vignetteEnabled=true,vignetteAmount=45.0),plan.finishing,model,w,h)
                val beforeEffects=plan.withoutFinishing()
                val combinedExpected=NativeKernels.reference { effects.apply(renderer.render(input,beforeEffects),renderer=renderer) }
                val separate=effects.apply(renderer.render(input,beforeEffects),renderer=renderer)
                val fused=requireNotNull(effects.applyAfterDevelop(input,renderer,beforeEffects))
                fun difference(a:ByteArray,b:ByteArray)=a.indices.maxOf { abs((a[it].toInt() and 255)-(b[it].toInt() and 255)) }
                // Two quantized stages can amplify a one-level first-stage rounding difference.
                // Keep each stage's CPU bound above, and require fusion to preserve the existing
                // two-stage GPU output and not increase its maximum error against the CPU chain.
                val separateError=difference(combinedExpected.pixels,separate.pixels)
                val fusedError=difference(combinedExpected.pixels,fused.pixels)
                check(separateError<=2 && fusedError<=2) { "CPU-chain error exceeds the verified two-level bound: separate=$separateError fused=$fusedError" }
                check(fusedError<=separateError) { "fusion increased CPU-chain error: $separateError to $fusedError" }
                Log.i("LightlyNative","CHAIN CPU max separate=$separateError fused=$fusedError")
                checkPixels("fused versus separate GPU $style",separate.pixels,fused.pixels)
                val combinedTimes=(1..5).map { val start=System.nanoTime();effects.applyAfterDevelop(input,renderer,beforeEffects);(System.nanoTime()-start)/1e6 }
                Log.i("LightlyNative","COMBINED $style ${combinedTimes.sorted()}")
            }
            // Consecutive recipes deliberately share the source: this exercises GPU cache invalidation.
            for((cw,ch) in listOf(127 to 93,93 to 127)) {
                val photo=Rgba8Image(cw,ch,kotlin.random.Random(16).nextBytes(cw*ch*4))
                for(amount in listOf(0.0,27.0,100.0)) for(kind in listOf(InkKind.STROKE,InkKind.OVERLAY)) {
                    val effects=EffectsParams(grainEnabled=true,grainAmount=amount,grainSize=amount,grainRoughness=amount,grainSeed=0xffffffffL,
                        vignetteEnabled=true,vignetteAmount=amount,vignetteSize=amount,vignetteSoftness=100-amount,
                        leakEnabled=true,leakStyle="prism",leakRotation=amount-50,leakX=amount,leakY=100-amount,
                        selectiveColours=listOf(KeptColour(.5,0.0,0.0),KeptColour(.6,.12,-.08)),selectiveRange=amount,selectiveStrength=amount,
                        ink=InkParams(kind,GreyImage(31,29,kotlin.random.Random(19).nextBytes(31*29)),x=amount,y=100-amount,size=35+amount*.65,rotation=amount,paper="#B0D5E7",intensity=amount))
                    val stage=EffectsStage(effects,FinishingRecipe.NEUTRAL,model,cw,ch)
                    val expected=NativeKernels.reference{stage.apply(photo,renderer=renderer)}
                    checkPixels("controls $cw $kind $amount",expected.pixels,stage.apply(photo,renderer=renderer).pixels)
                }
            }
            val bitmap=context.assets.open("backgrounds/landscape_03.jpg").use { android.graphics.BitmapFactory.decodeStream(it) }
            val photoBitmap=android.graphics.Bitmap.createScaledBitmap(bitmap,1600,1600*bitmap.height/bitmap.width,true)
            val argb=IntArray(photoBitmap.width*photoBitmap.height);photoBitmap.getPixels(argb,0,photoBitmap.width,0,0,photoBitmap.width,photoBitmap.height)
            val rgba=ByteArray(argb.size*4);argb.forEachIndexed { i,c -> rgba[i*4]=(c shr 16).toByte();rgba[i*4+1]=(c shr 8).toByte();rgba[i*4+2]=c.toByte();rgba[i*4+3]=(c ushr 24).toByte() }
            val photo=Rgba8Image(photoBitmap.width,photoBitmap.height,rgba)
            for(id in listOf("look-ce85dea9dbeff5240603","look-28da3e8df3f7f61eb3fc","look-245b1b4e00e554cf0d29")) {
                val preset=requireNotNull(library.pack.preset(id))
                val plan=DevelopRenderPlan.of(model,auto,.5f,library.lutFor(preset),preset.recipe,.85f)
                val expected=NativeKernels.reference { renderer.render(photo,plan) }
                checkPixels("photo $id",expected.pixels,renderer.render(photo,plan).pixels)
                val times=(1..8).map { if(it==1)NativeKernels.profileNext();val start=System.nanoTime();renderer.render(photo,plan);(System.nanoTime()-start)/1e6 }
                Log.i("LightlyNative","PHOTO $id ${times.sorted()}")
                val fitted = BackgroundSession.resize(photo, 1184, 790)
                val fittedExpected = NativeKernels.reference { renderer.render(fitted, plan) }
                checkPixels("fitted photo $id", fittedExpected.pixels, renderer.render(fitted, plan).pixels)
            }
            val cataloguePhoto=Rgba8Image(67,43,kotlin.random.Random(84).nextBytes(67*43*4))
            for(preset in library.pack.categories.flatMap { it.presets }.drop(catalogueStart).take(catalogueCount)) for(amount in listOf(.2f,.55f,.85f,1f)) {
                val plan=DevelopRenderPlan.of(model,auto,.5f,library.lutFor(preset),preset.recipe,amount)
                val expected=NativeKernels.reference { renderer.render(cataloguePhoto,plan) }
                checkPixels("catalogue ${preset.id} $amount",expected.pixels,renderer.render(cataloguePhoto,plan).pixels)
            }
            check(NativeKernels.hardwareImages) { "Hardware preview path fell back" }
            Log.i("LightlyNative","PASS $checked cases hardware=true")
        } catch(t:Throwable) {Log.e("LightlyNative","FAIL",t)} finally {pool.shutdown()}
    }
}
