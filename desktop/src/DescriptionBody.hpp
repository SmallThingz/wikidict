#pragma once
#include "CompiledContent.hpp"
#include <QColor>
#include <QJsonDocument>
#include <QTextFormat>
#include <QVariantMap>

namespace DescriptionBody {
inline constexpr int paintProperty = QTextFormat::UserProperty + 0x5882;
inline QJsonObject box(const QJsonObject &source) {
    const auto kind=source.value("kind").toString();
    const auto path=source.value("list_path").toString();
    CompiledContent::require((kind=="example" && path.endsWith("#:")) || (kind=="indent" && path.endsWith(':')));
    CompiledContent::require(source.value("depth").toInt(-1)==path.size() && source.value("spans").toArray().isEmpty());
    for (const char *key : {"table","container","feature","flow","figure","rule_style"})
        CompiledContent::require(!CompiledContent::present(source.value(QLatin1String(key))));
    const auto description=source.value("description_body").toObject();
    const auto owned=description.value("box").toObject();
    const auto before=description.value("before").toObject();
    CompiledContent::require(description.size()==2 && owned.value("blocks").isArray() && !owned.value("blocks").toArray().isEmpty()
        && !CompiledContent::present(owned.value("disclosure")) && before.size()==5);
    auto style=owned.value("style").toObject();
    for (const auto &key:style.keys())
        CompiledContent::require(key=="positioning" || key=="margins" || key=="padding" || key=="owner_font_scale");
    CompiledContent::require(style.take("positioning")==QJsonValue(QStringLiteral("relative_auto")));
    for (const char *side:{"top","right","bottom","left"}) {
        const auto margin=style.value("margins").toObject().value(QLatin1String(side)).toObject();
        const auto padding=style.value("padding").toObject().value(QLatin1String(side)).toObject();
        CompiledContent::require(margin.value("value").toDouble(-1)==0 && (QLatin1String(side)==QLatin1String("left")
            ? padding.value("value").toDouble(-1)>0 : padding.value("value").toDouble(-1)==0));
    }
    // The only positioned child is this frame's generated ::before stroke. Its
    // containing box is the physical DD padding box. Keep the semantic owner in
    // the frame metadata and lay out the original child block list normally.
    auto projected=owned;projected.insert("style",style);
    return {{"kind","container"},{"spans",QJsonArray{}},{"container",projected}};
}
inline QVariantMap paint(const QJsonObject &source,qreal bodyEm,bool dark) {
    const auto before=source.value("description_body").toObject().value("before").toObject();
    QVariantMap map;
    for (const char *key:{"left","top","bottom","width"}) {
        const auto length=before.value(QLatin1String(key)).toObject();
        const auto unit=length.value("unit").toString();const auto value=length.value("value").toDouble(-1);
        CompiledContent::require(length.size()==2 && (unit=="em"||unit=="px") && std::isfinite(value) && value>=0);
        map.insert(QLatin1String(key),value*(unit=="em"?bodyEm:1));
    }
    CompiledContent::require(map.value("width").toDouble()>0);
    const auto fill=before.value("fill").toObject(); const auto pair=fill.value("light_dark").toObject();
    const auto color=[](const QJsonValue &v){QString s=v.toString();QColor c(s);CompiledContent::require(s.size()==7&&c.isValid()&&c.name()==s);return c;};
    CompiledContent::require(fill.size()==1 && ((fill.contains("rgb")) || (pair.size()==2 && pair.contains("light") && pair.contains("dark"))));
    if (fill.contains("rgb")) map.insert("ink",color(fill.value("rgb")));
    else {const auto light=color(pair.value("light")), night=color(pair.value("dark"));map.insert("ink",dark?night:light);}
    map.insert("source",QJsonDocument(source).toJson(QJsonDocument::Compact));return map;
}
}
