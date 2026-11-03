package app.smallthingz.dict

import java.io.InputStream
import java.io.FilterInputStream
import java.io.ByteArrayOutputStream

internal class BaselineCountingInput(input: InputStream): FilterInputStream(input) {
    var position=0L;private set
    override fun read():Int = super.read().also { if(it>=0)position++ }
    fun bytes(n:Int):ByteArray { val b=ByteArray(n);for(i in b.indices){val x=read();require(x>=0){"Truncated dictionary"};b[i]=x.toByte()};return b }
    fun nul():String { val b=ByteArrayOutputStream();while(true){val x=read();require(x>=0 && b.size()<65536){"Invalid title"};if(x==0)break;b.write(x)};return b.toByteArray().decodeToString(throwOnInvalidSequence=true) }
    fun varuint():Long { var value=0L;var shift=0;while(true){val x=read();require(x>=0 && shift<63);value=value or ((x and 127).toLong() shl shift);if(x and 128==0){require(shift==0||x!=0);return value};shift+=7} }
    fun skipFully(n:Long){var left=n;while(left>0){val skipped=`in`.skip(left);if(skipped==0L){require(read()>=0);left--}else{position+=skipped;left-=skipped}}}
}
