package com.lightlylabs.lightly.develop

import kotlin.math.*

/** Stable source-width coordinates, including when an export is rendered tile by tile. */
object PaperBorder {
    fun noise(x: Double, y: Double): Double {
        fun hash(x: Int, y: Int): Double {
            var n = x * 374761393 + y * 668265263
            n = (n xor (n ushr 13)) * 1274126177
            return ((n xor (n ushr 16)) and 65535) / 65535.0
        }
        val ix = floor(x).toInt(); val iy = floor(y).toInt()
        val fx = x-floor(x); val fy = y-floor(y)
        val u = fx*fx*(3-2*fx); val v = fy*fy*(3-2*fy)
        return (hash(ix,iy)*(1-u)+hash(ix+1,iy)*u)*(1-v)+(hash(ix,iy+1)*(1-u)+hash(ix+1,iy+1)*u)*v
    }

    fun paint(b: BorderParams, p: BorderStage.Placement, tile: PixelRect, out: ByteArray) {
        val scale = p.frameWidth.toDouble()
        val rgb = b.colour.removePrefix("#").toLong(16)
        val base = doubleArrayOf(((rgb shr 16) and 255).toDouble(), ((rgb shr 8) and 255).toDouble(), (rgb and 255).toDouble())
        val amplitude = when(b.paperFinish) { "clean" -> 0.0; "deckled" -> 0.0025; else -> 0.009 }
        val limit = ceil(amplitude * scale + 2).toInt()
        for (row in 0 until tile.height) for (col in 0 until tile.width) {
            val x = tile.x + col; val y = tile.y + row
            val px = x-p.side; val py = y-p.top
            val inside = px >= 0 && py >= 0 && px < p.frameWidth && py < p.frameHeight
            val distance = minOf(px,py,p.frameWidth-1-px,p.frameHeight-1-py)
            if (inside && distance > limit) continue
            val u = x/scale; val v = y/scale
            val edge = amplitude*scale*(0.18+0.55*noise(u*93,v*93)+0.27*noise(u*431,v*431))
            val coverage = if (inside) (edge-distance).coerceIn(0.0,1.0) else 1.0
            if (coverage <= 0) continue
            val fibre = (noise(u*850,v*210)-0.5)*13+(noise(u*230,v*230)-0.5)*7
            val variation = fibre*b.texture/100
            val rim = if(inside && b.paperFinish != "clean") 5.0 else 0.0
            val i = (row*tile.width+col)*4
            for(c in 0..2) {
                val paper = (base[c]+variation+rim).coerceIn(0.0,255.0)
                out[i+c] = ((out[i+c].toInt() and 255)*(1-coverage)+paper*coverage).roundToInt().coerceIn(0,255).toByte()
            }
        }
    }
}
