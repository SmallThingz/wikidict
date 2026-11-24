#pragma once

#include "SemanticHtml.hpp"
#include <QTextBlock>
#include <QTextCursor>
#include <QTextTable>

namespace CompiledClippedAbsolute {
inline QString marker(const QJsonObject &carrier, int sourceRun)
{
    const auto payload = carrier.value("clipped_absolute").toObject();
    const auto children = payload.value("children").toArray();
    const QJsonObject one{{"unit","px"},{"value",1}};
    const QJsonObject minus{{"length",QJsonObject{{"unit","px"},{"value",-1}}}};
    const QJsonObject margins{{"top",minus},{"right",minus},{"bottom",minus},{"left",minus}};
    if (payload.size()!=5 || payload.value("static_parent_direction")!="ltr" ||
        payload.value("width").toObject()!=one || payload.value("height").toObject()!=one ||
        payload.value("margin").toObject()!=margins || children.size()!=1 || !children.first().isObject())
        throw std::runtime_error("unsupported clipped absolute payload");
    const auto child=children.first().toObject();
    const auto plain = [](const QJsonObject &obj, bool owner) {
        if (obj.value("kind")!="text" || !obj.value("text").isString()) return false;
        for (auto it=obj.begin();it!=obj.end();++it) {
            if (it.key()=="text" || it.key()=="kind" || (owner && it.key()=="clipped_absolute")) continue;
            const auto v=it.value();
            if (v.isNull() || (v.isString() && v.toString().isEmpty()) || (v.isBool() && !v.toBool())) continue;
            if ((it.key()=="role" && v=="normal") || (it.key()=="font_scale_basis" && v=="context")) continue;
            return false;
        }
        return true;
    };
    const auto literal=child.value("text").toString();
    if (!plain(carrier,true) || !carrier.value("text").toString().isEmpty() ||
        !plain(child,false) || literal.isEmpty() || literal.size()>4096 || literal.simplified()!=literal)
        throw std::runtime_error("unsupported clipped absolute literal");
    return SemanticHtml::scaledText(literal.toHtmlEscaped(),1,{},SemanticHtml::Basis::Context,
        0,false,false,false,0,{},true,sourceRun,{},-1,0,false,{},false,{},0,0,{},{},{},{},{},literal);
}

inline void install(QTextDocument *doc, QVariantList &descriptors)
{
    for (auto block=doc->begin(); block.isValid(); block=block.next()) {
        for (auto it=block.begin();!it.atEnd();++it) {
            const auto frag=it.fragment();
            if (!frag.isValid() || !frag.charFormat().hasProperty(SemanticHtml::clippedAbsoluteProperty)) continue;
            const auto value=frag.charFormat().property(SemanticHtml::clippedAbsoluteProperty);
            if (value.metaType().id()!=QMetaType::QString || frag.text()!=value.toString() ||
                !QTextCursor(block).currentTable()) throw std::runtime_error("clipped source interval changed");
            const int first=frag.position(), last=first+frag.length();
            const auto text=[](int a,int b) { return QVariantMap{{"kind","text"},{"first",a},{"last",b}}; };
            const QVariantMap piece{{"kind","clippedAbsolute"},{"first",first},{"last",last},
                {"owner","article"},{"sizeCssPx",QSizeF(1,1)},{"marginCssPx",-1.0}};
            const int b=block.position(), e=b+block.length()-1;
            bool registered=false;
            for (auto &raw:descriptors) {
                auto owner=raw.toMap();
                if (owner.value("last").toInt()<=b || owner.value("first").toInt()>=e) continue;
                if (registered || owner.value("first").toInt()!=b || owner.value("last").toInt()!=e)
                    throw std::runtime_error("clipped source crosses existing owner");
                auto parts=owner.value("parts").toList();
                bool found=false;
                for (int i=0;i<parts.size();++i) {
                    const auto part=parts.at(i).toMap();
                    if (part.value("kind")!="text") continue;
                    const int a=part.value("first").toInt(), z=part.value("last").toInt();
                    if (a>first || z<last) continue;
                    if (found) throw std::runtime_error("overlapping clipped source interval");
                    parts.removeAt(i);
                    if (a<first) parts.insert(i++,text(a,first));
                    parts.insert(i++,piece);
                    if (last<z) parts.insert(i,text(last,z));
                    found=true;
                }
                if (!found) throw std::runtime_error("clipped text is outside ordinary native flow");
                owner.insert("parts",parts); raw=owner; registered=true;
            }
            if (!registered) {
                QVariantList parts;
                if (b<first) parts.append(text(b,first));
                parts.append(piece);
                if (last<e) parts.append(text(last,e));
                descriptors.append(QVariantMap{{"first",b},{"last",e},{"direction",int(Qt::LeftToRight)},
                    {"joins",QVariantList{}},{"parts",parts}});
            }
        }
    }
}
}
