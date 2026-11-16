// Enhance step 2d check workload (phone/mathcheck/run.sh): JVM entry point comparing package old (earlier commit) with fresh.
fun main() {
    val a = old.check()
    val b = fresh.check()
    var same = true
    for ((x, y) in a.zip(b)) {
        val ok = x.second == y.second
        same = same && ok
        println("%-14s %s  step2c %6d ms  step2d %6d ms".format(x.first, if (ok) "identical" else "DIFFERENT", x.third, y.third))
    }
    println(if (same) "ALL IDENTICAL" else "MISMATCH")
}
