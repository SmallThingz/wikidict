#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QPointF>
#include <QRectF>
#include <QSizeF>
#include <QStringList>
#include <QUrl>
#include <QVector>
#include <cmath>
#include <stdexcept>

// Compiled occurrence data only. Arithmetic follows the retained
// presentation_image_map.zig reference; no source parsing or asset inference.
namespace CompiledImageMap {
struct GeometryUnavailable final : std::runtime_error {
    GeometryUnavailable() : std::runtime_error("image map geometry unavailable") {}
};
inline double checked(double value) {
    if (!std::isfinite(value)) throw GeometryUnavailable();
    return value;
}
inline bool positive(double value) { return std::isfinite(value) && value > 0; }
inline void require(bool condition) {
    if (!condition) throw std::runtime_error("invalid compiled image map");
}
inline QJsonObject action(const QJsonValue &value) {
    require(value.isObject());
    const QJsonObject object = value.toObject();
    require(object.size() == 4 && object.value("kind").isString()
        && object.value("target").isString() && object.value("label").isString()
        && object.contains("target_fragment")
        && (object.value("target_fragment").isNull() || object.value("target_fragment").isString()));
    const QString kind = object.value("kind").toString();
    require(kind == QStringLiteral("internal") || kind == QStringLiteral("external"));
    require(kind == QStringLiteral("internal")
        ? (!object.value("target").toString().isEmpty() || !object.value("target_fragment").isNull())
        : (!object.value("target").toString().isEmpty() && object.value("target_fragment").isNull()));
    return object;
}
inline QUrl actionUrl(const QJsonObject &value) {
    const QJsonObject a = action(value);
    const QString target = a.value("target").toString();
    if (a.value("kind") == QStringLiteral("external")) {
        QUrl url(target);
        if (target.startsWith(QStringLiteral("//")) && url.scheme().isEmpty()) url.setScheme(QStringLiteral("https"));
        return url.isValid() && !url.host().isEmpty() && (url.scheme() == "https" || url.scheme() == "http") ? url : QUrl{};
    }
    QString encoded = QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target));
    if (!a.value("target_fragment").isNull())
        encoded += QLatin1Char('#') + QString::fromLatin1(QUrl::toPercentEncoding(a.value("target_fragment").toString()));
    return QUrl(encoded);
}
inline QJsonObject validate(const QJsonValue &value) {
    require(value.isObject());
    const QJsonObject map = value.toObject();
    require(map.size() == 3 && map.value("regions").isArray() && map.value("description").isString()
        && map.contains("default_action"));
    require(QStringList{"none", "top_right", "bottom_right", "bottom_left", "top_left"}
        .contains(map.value("description").toString()));
    qsizetype items = 1 << 20;
    qsizetype stringBytes = 0;
    const auto chargeAction = [&](const QJsonValue &value) {
        const QJsonObject a = action(value);
        for (const QString &key : {QStringLiteral("target"), QStringLiteral("target_fragment"), QStringLiteral("label")}) {
            const qsizetype size = a.value(key).toString().toUtf8().size();
            require(size <= 32 * 1024 * 1024 && stringBytes <= 32 * 1024 * 1024 - size);
            stringBytes += size;
        }
    };
    if (!map.value("default_action").isNull()) { require(items-- > 0); chargeAction(map.value("default_action")); }
    for (const QJsonValue &value : map.value("regions").toArray()) {
        require(items-- > 0 && value.isObject());
        const QJsonObject region = value.toObject();
        require(region.size() == 3 && region.value("shape").isString() && region.value("coordinates").isArray());
        const QString shape = region.value("shape").toString();
        const QJsonArray coordinates = region.value("coordinates").toArray();
        require((shape == "rectangle" && coordinates.size() == 4)
            || (shape == "circle" && coordinates.size() == 3)
            || (shape == "polygon" && coordinates.size() >= 6 && coordinates.size() % 2 == 0));
        require(coordinates.size() <= items); items -= coordinates.size();
        for (const QJsonValue &coordinate : coordinates)
            require(coordinate.isDouble() && std::isfinite(coordinate.toDouble()));
        chargeAction(region.value("action"));
    }
    return map;
}
struct Region { QString shape; QVector<double> coordinates; QJsonObject action; };
struct Hit {
    enum Kind { Outside, None, RegionAction, DefaultAction, Unavailable } kind = None;
    qsizetype index = -1;
    QJsonObject action;
};
inline bool onSegment(QPointF a, QPointF b, QPointF p) {
    if (p.x() < qMin(a.x(), b.x()) || p.x() > qMax(a.x(), b.x())
        || p.y() < qMin(a.y(), b.y()) || p.y() > qMax(a.y(), b.y())) return false;
    const double dx = checked(b.x() - a.x()), dy = checked(b.y() - a.y());
    const double px = checked(p.x() - a.x()), py = checked(p.y() - a.y());
    return checked(dx * py) == checked(dy * px);
}
inline bool contains(const Region &region, QPointF point) {
    const auto &c = region.coordinates;
    if (region.shape == "rectangle") {
        const double left = qMin(c[0], c[2]), right = qMax(c[0], c[2]);
        const double top = qMin(c[1], c[3]), bottom = qMax(c[1], c[3]);
        return left != right && top != bottom && point.x() >= left && point.x() <= right
            && point.y() >= top && point.y() <= bottom;
    }
    if (region.shape == "circle") {
        if (c[2] <= 0) return false;
        const double dx = checked(point.x() - c[0]), dy = checked(point.y() - c[1]);
        return checked(checked(dx * dx) + checked(dy * dy)) <= checked(c[2] * c[2]);
    }
    bool inside = false;
    QPointF previous(c[c.size() - 2], c[c.size() - 1]);
    for (qsizetype i = 0; i < c.size(); i += 2) {
        const QPointF current(c[i], c[i + 1]);
        if (onSegment(previous, current, point)) return true;
        if ((previous.y() > point.y()) != (current.y() > point.y())) {
            const double fraction = checked(checked(point.y() - current.y()) / checked(previous.y() - current.y()));
            const double crossing = checked(current.x() + checked(fraction * checked(previous.x() - current.x())));
            if (point.x() < crossing) inside = !inside;
        }
        previous = current;
    }
    return inside;
}
struct Prepared {
    QVector<Region> regions;
    QSizeF layout;
    QJsonValue defaultAction;
    Hit hit(const QRectF &paintedContent, QPointF point) const {
        try {
            if (!std::isfinite(paintedContent.x()) || !std::isfinite(paintedContent.y())
                || !positive(paintedContent.width()) || !positive(paintedContent.height())
                || !std::isfinite(point.x()) || !std::isfinite(point.y())) throw GeometryUnavailable();
            if (point.x() < paintedContent.x() || point.y() < paintedContent.y()) return {Hit::Outside};
            const double dx = checked(point.x() - paintedContent.x()), dy = checked(point.y() - paintedContent.y());
            if (dx >= paintedContent.width() || dy >= paintedContent.height()) return {Hit::Outside};
            const QPointF local(checked((dx / paintedContent.width()) * layout.width()),
                                checked((dy / paintedContent.height()) * layout.height()));
            for (qsizetype i = 0; i < regions.size(); ++i)
                if (contains(regions[i], local)) return {Hit::RegionAction, i, regions[i].action};
            if (defaultAction.isObject()) return {Hit::DefaultAction, -1, defaultAction.toObject()};
            return {Hit::None};
        } catch (const GeometryUnavailable &) { return {Hit::Unavailable}; }
    }
};
inline Prepared prepare(const QJsonObject &input, QSizeF original, QSizeF layout) {
    const QJsonObject map = validate(input);
    for (const double n : {original.width(), original.height()})
        if (!positive(n) || n > 4294967295.0 || std::floor(n) != n) throw GeometryUnavailable();
    if (!positive(layout.width()) || !positive(layout.height())) throw GeometryUnavailable();
    const double scale = checked(checked(layout.width() + layout.height()) / checked(original.width() + original.height()));
    if (scale <= 0) throw GeometryUnavailable();
    Prepared result; result.layout = layout; result.defaultAction = map.value("default_action");
    for (const QJsonValue &value : map.value("regions").toArray()) {
        const QJsonObject object = value.toObject();
        Region region; region.shape = object.value("shape").toString(); region.action = object.value("action").toObject();
        for (const QJsonValue &number : object.value("coordinates").toArray())
            region.coordinates.append(checked(std::round(checked(number.toDouble() * scale))));
        result.regions.append(region);
    }
    return result;
}
} // namespace CompiledImageMap
