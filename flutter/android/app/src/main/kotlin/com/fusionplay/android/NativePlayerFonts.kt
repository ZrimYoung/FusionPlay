package com.fusionplay.android

import android.graphics.Typeface
import android.graphics.fonts.Font
import android.graphics.fonts.FontFamily
import android.graphics.fonts.SystemFonts
import android.os.Build
import androidx.annotation.RequiresApi
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

internal object NativePlayerFonts {
    data class Face(val id: String, val style: String, val weight: Int, val italic: Boolean)
    data class Family(val name: String, val faces: List<Face>)

    private val typefaces = ConcurrentHashMap<String, Typeface>()
    private val families by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) Api29.families() else emptyList()
    }

    fun installedFamilies(): List<Family> = families

    fun faceLabel(faceId: String): String? =
        if (faceId.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) null else Api29.faceLabel(faceId)

    fun typeface(faceId: String): Typeface? {
        if (faceId.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return typefaces[faceId] ?: Api29.typeface(faceId)?.also { typefaces[faceId] = it }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private object Api29 {
        private val namesByFace = ConcurrentHashMap<String, Map<Int, String>>()
        private val fonts by lazy {
            SystemFonts.getAvailableFonts().mapNotNull { font ->
                font.file?.let { file ->
                    val style = font.style
                    val id = "${file.absolutePath}#${font.ttcIndex}/${style.weight}/${style.slant}"
                    id to font
                }
            }.toMap()
        }

        fun typeface(id: String): Typeface? = fonts[id]?.let { font ->
            runCatching {
                Typeface.CustomFallbackBuilder(FontFamily.Builder(font).build())
                    .setSystemFallback("sans-serif")
                    .setStyle(font.style)
                    .build()
            }.getOrNull()
        }

        fun faceLabel(id: String): String? = fonts[id]?.let { font ->
            val names = names(id, font)
            val family = names[16] ?: names[1] ?: return@let null
            val style = names[17] ?: names[2]
            if (style == null) family else "$family · $style"
        }

        private fun names(id: String, font: Font): Map<Int, String> = namesByFace.computeIfAbsent(id) {
            runCatching { readNames(font.buffer, font.ttcIndex) }.getOrDefault(emptyMap())
        }

        fun families(): List<Family> = fonts.mapNotNull { (id, font) ->
            val names = names(id, font)
            val family = names[16] ?: names[1] ?: return@mapNotNull null
            val style = font.style
            val styleName = names[17] ?: names[2] ?: style.weight.toString()
            family to Face(id, styleName, style.weight, style.slant != 0)
        }.groupBy({ it.first }, { it.second }).map { (name, faces) ->
            Family(name, faces.sortedWith(compareBy(Face::italic, Face::weight, Face::style)).distinctBy {
                Triple(it.style, it.weight, it.italic)
            })
        }.sortedBy { it.name.lowercase() }
    }

    // Android exposes the font binaries and their styles, but not the family names.
    // Read the four OpenType naming fields used by the picker from the selected TTC face.
    private fun readNames(source: ByteBuffer, index: Int): Map<Int, String> {
        val data = source.duplicate().order(ByteOrder.BIG_ENDIAN)
        fun u16(offset: Int) = data.getShort(offset).toInt() and 0xffff
        val face = if (data.getInt(0) == 0x74746366) {
            if (index !in 0 until data.getInt(8)) return emptyMap()
            data.getInt(12 + index * 4)
        } else 0
        val table = (0 until u16(face + 4)).asSequence().map { face + 12 + it * 16 }
            .firstOrNull { data.getInt(it) == 0x6e616d65 } ?: return emptyMap()
        val nameOffset = data.getInt(table + 8)
        val strings = nameOffset + u16(nameOffset + 4)
        val names = mutableMapOf<Int, Pair<Int, String>>()
        repeat(u16(nameOffset + 2)) { entry ->
            val record = nameOffset + 6 + entry * 12
            val id = u16(record + 6)
            val platform = u16(record)
            if ((id == 1 || id == 2 || id == 16 || id == 17) && (platform == 0 || platform == 3)) {
                val priority = if (u16(record + 4) == 0x0409) 2 else 1
                if (priority > (names[id]?.first ?: 0)) {
                    val size = u16(record + 8)
                    val start = strings + u16(record + 10)
                    if (size in 2..1024 && size % 2 == 0 && start in 0..(data.limit() - size)) {
                        val text = ByteArray(size).also { data.position(start); data.get(it) }
                            .toString(Charsets.UTF_16BE).trim()
                        if (text.isNotEmpty()) names[id] = priority to text
                    }
                }
            }
        }
        return names.mapValues { it.value.second }
    }
}
