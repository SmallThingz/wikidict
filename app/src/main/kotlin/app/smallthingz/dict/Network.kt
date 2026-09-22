package app.smallthingz.dict

import java.io.FilterInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI

object Network {
    fun open(address: String): InputStream {
        var uri = URI(address)
        repeat(6) {
            require(uri.scheme == "https" && uri.host != null && uri.userInfo == null) { "Downloads require HTTPS" }
            val c = uri.toURL().openConnection() as HttpURLConnection
            c.connectTimeout = 15000; c.readTimeout = 20000; c.instanceFollowRedirects = false
            c.setRequestProperty("User-Agent", "Wikidict-Android/0.3 (https://github.com/SmallThingz/wikidict-android)")
            try {
                val status = c.responseCode
                if (status in listOf(301,302,303,307,308)) {
                    val next = c.getHeaderField("Location") ?: error("Invalid redirect")
                    uri = uri.resolve(next); c.disconnect()
                } else {
                    require(status in 200..299) { if(status==404) "Catalogue or file has not been published yet" else "Download failed (HTTP $status)" }
                    return object: FilterInputStream(c.inputStream) { override fun close() { try { super.close() } finally { c.disconnect() } } }
                }
            } catch(e:java.net.UnknownHostException) { c.disconnect();throw java.io.IOException("Cannot resolve the server. Check your connection or DNS settings.",e) } catch(e:Exception) { c.disconnect();throw e }
        }
        error("Too many download redirects")
    }
    fun read(url:String, max:Int):ByteArray = open(url).use { input ->
        val out=java.io.ByteArrayOutputStream();val b=ByteArray(16384)
        while(true){val n=input.read(b);if(n<0)break;require(out.size()+n<=max){"Download exceeds limit"};out.write(b,0,n)}
        out.toByteArray()
    }
}
