#pragma once

#include <QByteArrayView>
#include <QtCore/qtenvironmentvariables.h>

namespace WikiDict {

inline void configureAudioOnlyPlayback()
{
#if defined(Q_OS_LINUX)
    // Qt's FFmpeg backend probes video devices during initialization and codec
    // enumeration, even for audio-only playback. Keep explicit backend choices.
    if (!qEnvironmentVariableIsSet("QT_FFMPEG_DECODING_HW_DEVICE_TYPES"))
        qputenv("QT_FFMPEG_DECODING_HW_DEVICE_TYPES", "");
    if (!qEnvironmentVariableIsSet("QT_FFMPEG_ENCODING_HW_DEVICE_TYPES"))
        qputenv("QT_FFMPEG_ENCODING_HW_DEVICE_TYPES", "");
#endif
}

}
