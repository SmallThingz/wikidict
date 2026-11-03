#pragma once

#include "LibraryStore.hpp"
#include <QPair>
#include <QStringList>

// Internal transaction recovery shared with the focused storage regression.
namespace LibraryStorage::detail {
void beginMutation(const QString &root, QTemporaryDir &directory, const QStringList &paths);

}
