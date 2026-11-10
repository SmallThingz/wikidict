#pragma once

#include "CompiledContent.hpp"
#include "MediaPanel.hpp"
#include <QSizeF>
#include <cmath>
#include <limits>
#include <optional>

namespace FigureSizing {
enum class Policy { Intrinsic, OriginalWidthWithHeightBound, RequestedFit, RequestedFitCapOriginalWidth };
struct Request {
    Policy policy;
    std::optional<quint32> width;
    std::optional<quint32> height;
};

inline std::optional<quint32> axis(const QJsonValue &value) {
    if (value.isNull() || value.isUndefined()) return std::nullopt;
    const double number = value.toDouble(-1);
    CompiledContent::require(value.isDouble() && std::isfinite(number) && number > 0
        && number <= std::numeric_limits<quint32>::max() && std::floor(number) == number);
    return quint32(number);
}
inline Request request(const QJsonObject &figure) {
    const QJsonValue value = figure.value(QStringLiteral("sizing"));
    CompiledContent::require(value.isString());
    const QString name = value.toString();
    Policy policy;
    if (name == QStringLiteral("intrinsic")) policy = Policy::Intrinsic;
    else if (name == QStringLiteral("original_width_with_height_bound")) policy = Policy::OriginalWidthWithHeightBound;
    else if (name == QStringLiteral("requested_fit")) policy = Policy::RequestedFit;
    else {
        CompiledContent::require(name == QStringLiteral("requested_fit_cap_original_width"));
        policy = Policy::RequestedFitCapOriginalWidth;
    }
    const auto image = CompiledContent::object(CompiledContent::object(figure.value(QStringLiteral("image_span")))
        .value(QStringLiteral("image")));
    Request result{policy, axis(image.value(QStringLiteral("width_px"))), axis(image.value(QStringLiteral("height_px")))};
    const QString format = figure.value(QStringLiteral("format")).toString();
    if (policy == Policy::Intrinsic || policy == Policy::OriginalWidthWithHeightBound) {
        CompiledContent::require(format == QStringLiteral("framed"));
        if (policy == Policy::OriginalWidthWithHeightBound) CompiledContent::require(result.height.has_value());
    } else CompiledContent::require(format == QStringLiteral("thumbnail") && result.width.has_value());
    return result;
}

inline std::optional<quint64> product(quint64 left, quint64 right) {
    if (right && left > std::numeric_limits<quint64>::max() / right) return std::nullopt;
    return left * right;
}
inline std::optional<quint64> positiveRound(quint64 numerator, quint64 denominator) {
    if (!denominator) return std::nullopt;
    quint64 quotient = numerator / denominator;
    const quint64 remainder = numerator % denominator;
    // Positive PHP round at half, without doubling a potentially large remainder.
    if (remainder >= denominator / 2 + denominator % 2) {
        if (quotient == std::numeric_limits<quint64>::max()) return std::nullopt;
        ++quotient;
    }
    return quotient;
}
inline std::optional<qreal> exactLayoutNumber(quint64 number) {
    const qreal converted = qreal(number);
    if (!std::isfinite(converted) || converted >= std::ldexp(qreal(1), 64)
        || quint64(converted) != number) return std::nullopt;
    return converted;
}
inline std::optional<quint32> originalAxis(qreal number) {
    if (!std::isfinite(number) || number <= 0 || number > std::numeric_limits<quint32>::max()
        || std::floor(number) != number) return std::nullopt;
    return quint32(number);
}

// The same pure original-axis fit serves verified API request planning and Ready
// layout assets. Raster pixels/device density never participate in this math.
inline std::optional<QSizeF> resolveOriginal(const Request &request, const QSizeF &original) {
    const auto originalWidth = originalAxis(original.width());
    const auto originalHeight = originalAxis(original.height());
    if (!originalWidth || !originalHeight) return std::nullopt;
    quint64 width = *originalWidth, height = *originalHeight;
    if (request.policy != Policy::Intrinsic) {
        if (request.policy == Policy::OriginalWidthWithHeightBound) {
            if (!request.height) return std::nullopt;
        } else {
            if (!request.width) return std::nullopt;
            width = *request.width;
            if (request.policy == Policy::RequestedFitCapOriginalWidth) width = qMin(width, quint64(*originalWidth));
        }
        if (!width || (request.height && !*request.height)) return std::nullopt;
        const auto scaledHeight = product(width, *originalHeight);
        const auto heightLimit = request.height ? product(*request.height, *originalWidth) : std::optional<quint64>{0};
        if (!scaledHeight || !heightLimit) return std::nullopt;
        if (request.height && *scaledHeight > *heightLimit) {
            const quint64 floorWidth = *heightLimit / *originalHeight;
            const bool fractional = *heightLimit % *originalHeight != 0;
            if (fractional && floorWidth == std::numeric_limits<quint64>::max()) return std::nullopt;
            const quint64 ceilWidth = floorWidth + quint64(fractional);
            const auto ceilProduct = product(ceilWidth, *originalHeight);
            if (!ceilProduct) return std::nullopt;
            const auto ceilHeight = positiveRound(*ceilProduct, *originalWidth);
            if (!ceilHeight) return std::nullopt;
            width = *ceilHeight > *request.height ? floorWidth : ceilWidth;
            if (!width) width = 1;
            // The source keeps this logical bound even when the one-pixel minimum
            // has a different physical backing aspect ratio.
            height = *request.height;
        } else {
            const auto rounded = positiveRound(*scaledHeight, *originalWidth);
            if (!rounded) return std::nullopt;
            height = *rounded; // A legal logical zero does not create a hit plane.
        }
    }
    const auto layoutWidth = exactLayoutNumber(width), layoutHeight = exactLayoutNumber(height);
    if (!layoutWidth || !layoutHeight) return std::nullopt;
    return QSizeF(*layoutWidth, *layoutHeight);
}
inline std::optional<QSizeF> resolve(const Request &request, const MediaPanel::InlineImageAsset &asset) {
    if (asset.state != MediaPanel::InlineImageState::Ready) return std::nullopt;
    return resolveOriginal(request, asset.intrinsic);
}
}
