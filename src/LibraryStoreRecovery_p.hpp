#pragma once

#include "LibraryStore.hpp"
#include <QPair>

// Internal transaction recovery shared with the focused storage regression.
namespace LibraryStorage::detail {
void rollbackImport(PreparedImport &prepared,
    const QList<QPair<QString, QString>> &backups, const QString &markerPath,
    bool published, bool markerCommitted);
}
