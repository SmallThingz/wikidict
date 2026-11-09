#pragma once

#include "CompiledContent.hpp"
#include <array>
#include <cmath>
#include <limits>
#include <optional>

namespace ParagraphBox {
enum Edge { Top, Right, Bottom, Left };
enum class Unit { Px, Em };
struct Length { Unit unit; double value; };
using SourceEdges = std::array<Length, 4>;
using Edges = std::array<qreal, 4>;
struct Source {
    std::optional<SourceEdges> margins;
    std::optional<SourceEdges> padding;
};
struct Resolved {
    Edges margins;
    Edges padding;
    bool authoredMargins;
};

inline Length length(const QJsonValue &value) {
    const auto object = CompiledContent::object(value);
    const auto number = object.value(QStringLiteral("value"));
    const QString unit = object.value(QStringLiteral("unit")).toString();
    const double n = number.toDouble(-1);
    CompiledContent::require(object.size() == 2 && number.isDouble() && std::isfinite(n)
        && n >= 0 && n <= std::numeric_limits<float>::max()
        && (unit == QStringLiteral("px") || unit == QStringLiteral("em")));
    return {unit == QStringLiteral("px") ? Unit::Px : Unit::Em, n};
}
inline SourceEdges edges(const QJsonValue &value) {
    const auto object = CompiledContent::object(value);
    CompiledContent::require(object.size() == 4);
    return {length(object.value(QStringLiteral("top"))), length(object.value(QStringLiteral("right"))),
        length(object.value(QStringLiteral("bottom"))), length(object.value(QStringLiteral("left")))};
}
inline std::optional<Source> source(const QJsonObject &block) {
    const auto value = block.value(QStringLiteral("style"));
    if (!CompiledContent::present(value)) return std::nullopt;
    CompiledContent::require(block.value(QStringLiteral("kind")).toString() == QStringLiteral("paragraph")
        && block.value(QStringLiteral("depth")).toInt() == 0
        && block.value(QStringLiteral("list_path")).toString().isEmpty()
        && !CompiledContent::present(block.value(QStringLiteral("table")))
        && !CompiledContent::present(block.value(QStringLiteral("feature")))
        && !CompiledContent::present(block.value(QStringLiteral("figure"))));
    const auto style = CompiledContent::object(value);
    Source result;
    for (auto it = style.begin(); it != style.end(); ++it) {
        CompiledContent::require(it.key() == QStringLiteral("margins") || it.key() == QStringLiteral("padding"));
        if (!CompiledContent::present(it.value())) continue;
        if (it.key() == QStringLiteral("margins")) result.margins = edges(it.value());
        else result.padding = edges(it.value());
    }
    CompiledContent::require(result.margins || result.padding);
    return result;
}

// Inputs and results are native layout coordinates. The caller derives the
// normal-body em and legacy contributions from the actual document/device and
// boundary; a child span's font is never a substitute. Source values stay separate.
inline std::optional<Resolved> resolve(const Source &source, const Edges &legacy, qreal normalBodyEm) {
    if (!std::isfinite(normalBodyEm) || normalBodyEm <= 0) return std::nullopt;
    Resolved result{legacy, {}, source.margins.has_value()};
    const auto resolved = [&](const Length &length) -> std::optional<qreal> {
        const double value = length.unit == Unit::Em ? length.value * normalBodyEm : length.value;
        // This is the paired native QFixed representability boundary, not a clamp.
        if (!std::isfinite(value) || value < 0 || value > 8388607.0) return std::nullopt;
        return qreal(value);
    };
    for (int edge = Top; edge <= Left; ++edge) {
        if (source.margins) {
            const auto value = resolved((*source.margins)[edge]); if (!value) return std::nullopt;
            result.margins[edge] = *value;
        }
        if (source.padding) {
            const auto value = resolved((*source.padding)[edge]); if (!value) return std::nullopt;
            result.padding[edge] = *value;
        }
        if (!std::isfinite(result.margins[edge]) || result.margins[edge] < 0
            || result.margins[edge] > 8388607.0) return std::nullopt;
    }
    return result;
}
inline std::optional<qreal> sum(qreal a, qreal b) {
    if (!std::isfinite(a) || !std::isfinite(b) || a < 0 || b < 0 || a > 8388607.0 - b)
        return std::nullopt;
    return a + b;
}
inline std::optional<qreal> boundary(const Resolved &before, const Resolved &after, bool sameOrdinaryFlow) {
    // Empty content is not a barrier. Only the caller's actual container/role
    // boundary decides adjacency; no empty-box self/through-collapse is invented.
    const auto outside = sameOrdinaryFlow
        ? std::optional<qreal>{qMax(before.margins[Bottom], after.margins[Top])}
        : sum(before.margins[Bottom], after.margins[Top]);
    if (!outside) return std::nullopt;
    const auto leading = sum(before.padding[Bottom], *outside);
    return leading ? sum(*leading, after.padding[Top]) : std::nullopt;
}
inline std::optional<qreal> first(const Resolved &value) { return sum(value.margins[Top], value.padding[Top]); }
inline std::optional<qreal> last(const Resolved &value) { return sum(value.padding[Bottom], value.margins[Bottom]); }
}
