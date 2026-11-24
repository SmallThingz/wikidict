#pragma once
#include <QJsonArray>
#include <QJsonObject>
#include <QVector>
#include <optional>

namespace TableCellLayers {
// Source rows are immutable. Only the exposed segment enters QTextTable's
// single-owner grid. The original ranges remain available for source queries.
struct FooterOverlap {
    int lowerRow, lowerCell, lowerColumn, lowerDeclaredRows;
    int upperRow, upperCell, upperColumns;
    int exposedRows() const { return upperRow - lowerRow; }
};

inline std::optional<FooterOverlap> finalCellCover(const QJsonObject &table, int cellBorder,
                                                  bool rendererDefaultBorder = false) {
    const QJsonArray rows = table.value("rows").toArray();
    if (rows.size() < 2) return {};
    const auto last = rows.last().toObject().value("cells").toArray();
    if (last.size() != 1) return {};
    const auto footer = last.first().toObject();
    const int width = footer.value("colspan").toInt(1);
    if (width <= 1 || width > 100 || footer.value("rowspan").toInt(1) != 1) return {};
    // Collapsed border arbitration and nonzero separate-cell gaps are painted
    // independently of a cell background. A covering fill cannot prove these
    // edges are hidden. Keep them on the unsimplified path.
    const auto tableStyle = table.value("style").toObject();
    const auto geometry = table.value("geometry").toObject();
    // A legacy table with no authored table geometry or style uses the same
    // one-pixel solid Reader border on every cell. At the covering seam both
    // incident edges use that same collapsed stroke. Keep that border in the
    // emitted table while applying the existing empty-cell projection.
    const bool uniformDefaultBorder = rendererDefaultBorder && cellBorder == 1 &&
        !table.contains("geometry") && !table.contains("style");
    if ((cellBorder != 0 && !uniformDefaultBorder) || geometry.value("cell_spacing").toInt() != 0
        || tableStyle.contains("corner_radii") || tableStyle.contains("opacity")) return {};
    for (const auto &value : rows) {
        const auto row = value.toObject();
        if (row.size() != 1 || !row.contains("cells")) return {};
        for (const auto &item : row.value("cells").toArray()) {
            const auto style = item.toObject().value("style").toObject();
            if (style.contains("border") || style.contains("border_edges")) return {};
        }
    }
    struct Track { int end = 0, start = 0, ordinal = 0; };
    QVector<Track> tracks(width);
    const int lastRow = int(rows.size()) - 1;
    for (int row = 0; row < lastRow; ++row) {
        int column = 0, ordinal = 0;
        const auto cells = rows.at(row).toObject().value("cells").toArray();
        for (const auto &value : cells) {
            while (column < width && tracks[column].end > row) ++column;
            const auto cell = value.toObject();
            const int w = cell.value("colspan").toInt(1), h = cell.value("rowspan").toInt(1);
            if (w < 1 || h < 1 || w > width-column) return {};
            for (int x = column; x < column+w; ++x) {
                if (tracks[x].end > row) return {};
                tracks[x] = {row + qMin(h, lastRow+1-row), row, ordinal};
            }
            column += w;
            ++ordinal;
        }
    }
    std::optional<FooterOverlap> overlap;
    for (int x = 0; x < width; ++x) {
        const auto &track = tracks[x];
        if (track.end <= lastRow) continue;
        if (x == 0 || overlap) return {};
        const auto source = rows.at(track.start).toObject().value("cells").toArray().at(track.ordinal).toObject();
        if (source.value("colspan").toInt(1) != 1 || !source.value("spans").isArray()
            || !source.value("spans").toArray().isEmpty() || source.value("nested_table").isObject()
            || source.value("blocks").isArray()) return {};
        // Layer flattening is lossless for a source-empty, undecorated lower
        // cell. An authored lower paint requires a fully opaque upper fill;
        // independently outlined edges require a dedicated paint pass.
        const auto lowerStyle = source.value("style").toObject();
        for (const auto &key : lowerStyle.keys())
            if (key != "width" && key != "min_width") return {};
        const auto upperStyle = footer.value("style").toObject();
        if (upperStyle.contains("opacity") && upperStyle.value("opacity").toDouble(-1) != 1) return {};
        if (source.value("background").isString() || tableStyle.contains("background")) {
            const auto color = footer.value("background").toString();
            if (color.size() != 7 || !color.startsWith('#')) return {};
            for (const auto digit : color.sliced(1))
                if (!QStringLiteral("0123456789abcdef").contains(digit)) return {};
        }
        overlap = FooterOverlap{track.start, track.ordinal, x, source.value("rowspan").toInt(), lastRow, 0, width};
    }
    return overlap;
}
}
