    static void bewPisany(const QString &library, const QString &out, const QJsonObject &fixture,
                          QJsonObject &report) {
        constexpr qsizetype jsonCap = 128 * 1024;
        const auto expectedResponse = object(pinned(fixture.value("reference_response").toObject(), jsonCap));
        const auto expectedEntry = expectedResponse.value("entries").toArray().at(0).toObject();
        const auto table = expectedEntry.value("sections").toArray().at(1).toObject()
            .value("blocks").toArray().at(5).toObject().value("table").toObject();
        const auto rows = table.value("rows").toArray();
        const auto endpointSource = rows.at(7).toObject().value("cells").toArray().at(5).toObject();
        const auto caption = QStringLiteral("Pemblèngkokan pisany");
        const auto italicText = QStringLiteral("pisany");
        const auto path = QStringLiteral("block-1-5/caption-toggle");
        const auto openLabel = QStringLiteral("Tèmprakin");
        const auto shutLabel = QStringLiteral("Gulung");
        constexpr int finalRow = 7, finalCol = 5;
        const auto saveDocument = [&](const QString &name, const QByteArray &raw) {
            report.insert("stage", name);
            report.insert("observed_json_bytes", qint64(raw.size()));
            check(raw.size() <= jsonCap, "bounded complete " + name);
            writeNew(out + '/' + name + ".json", raw);
        };
        const auto checkpoint = [&](const QString &name, const QJsonObject &data) {
            report.insert("stage", name);
            const auto raw = QJsonDocument(data).toJson(QJsonDocument::Compact);
            check(raw.size() <= 16 * 1024, "bounded checkpoint " + name);
            writeNew(out + "/bew-" + name + ".json", raw);
        };

        {
            DictApi api(library);
            api.select("Pol", "language");
            const auto response = api.lookup("pisany");
            saveDocument("ffi-response", response);
            const auto actual = object(response);
            const auto entries = actual.value("entries").toArray();
            if (entries.size() == 1 && entries.at(0).isObject())
                saveDocument("ffi-entry", QJsonDocument(entries.at(0).toObject()).toJson(QJsonDocument::Compact));
            check(api.root() == library && api.kind() == "language" && api.language() == "Pol"
                  && actual == expectedResponse && entries.size() == 1, "genuine Pol lookup equals complete retained response");
        }

        int authored = 0;
        int gridColumns = 0;
        for (const auto &rowValue : rows) {
            const auto cells = rowValue.toObject().value("cells").toArray();
            authored += int(cells.size());
            int width = 0;
            for (const auto &value : cells) {
                const auto cell = value.toObject();
                const auto span = cell.value("colspan").toInt();
                check(span > 0 && cell.value("rowspan").toInt() == 1, "supported authored span");
                width += span;
            }
            if (!gridColumns) gridColumns = width;
            check(width == gridColumns, "all authored rows cover the same grid width");
        }
        const auto endSpan = endpointSource.value("spans").toArray().at(0).toObject();
        check(rows.size() == 8 && authored == 48 && gridColumns == 7
              && endpointSource.value("colspan") == 2 && endpointSource.value("rowspan") == 1
              && endpointSource.value("spans").toArray().size() == 1 && endSpan.value("kind") == "text"
              && endSpan.value("text") == "pisanych" && endSpan.value("target") == "",
              "exact authored grid and final plain colspan cell");
        const auto sourceCaption = table.value("caption").toArray();
        check(sourceCaption.size() == 2 && sourceCaption.at(0).toObject().value("text") == "Pemblèngkokan "
              && sourceCaption.at(0).toObject().value("italic") == false
              && sourceCaption.at(1).toObject().value("text") == italicText
              && sourceCaption.at(1).toObject().value("italic") == true
              && table.value("caption_disclosure") == QJsonObject{{"initially_collapsed", true},
                  {"expand_label", openLabel}, {"collapse_label", shutLabel}},
              "exact authored caption spans and collapse policy");

        QTimer modal;
        QObject::connect(&modal, &QTimer::timeout, [&] {
            auto *box = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
            if (!box) return;
            report.insert("product_refusal", box->text().left(4096));
            box->reject();
        });
        modal.start(20);
        const auto settle = [](const std::function<bool()> &predicate) {
            QElapsedTimer elapsed;
            elapsed.start();
            while (!predicate() && elapsed.elapsed() < 15000) {
                QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
                QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
                QThread::msleep(2);
            }
            return predicate();
        };

        // A second independent window uses the same immutable ordinary records and its own Reading state.
        for (bool reopen : {false, true}) {
            MainWindow window(library, "pisany");
            window.resize(480, 700);
            window.show();
            window.activateWindow();
            const auto prefix = reopen ? QStringLiteral("reopen") : QStringLiteral("ui");
            const bool loaded = settle([&] { return !window.loading_; });
            saveDocument(prefix + "-response", window.currentResponse_.toJson(QJsonDocument::Compact));
            saveDocument(prefix + "-entry", QJsonDocument(window.currentEntry_).toJson(QJsonDocument::Compact));
            auto *reader = window.reading_;

            const auto occurrence = [&]() -> const CompiledDisclosure::Host::Occurrence * {
                const auto *host = window.readingDisclosures_.data();
                if (!host || !host->current() || !host->attached(reader->document(), reader->viewport())
                    || host->occurrences.size() != 1) return nullptr;
                const auto &row = host->occurrences.front();
                if (row.path != path || row.block != table || window.disclosureSources_.value(path) != table
                    || !row.caption.isValid() || !row.owner || !row.widget) return nullptr;
                return &row;
            };
            const auto button = [&]() -> CompiledDisclosure::Button * {
                const auto *row = occurrence();
                return row ? window.readingDisclosures_->button(path, table) : nullptr;
            };
            const auto captionStyle = [&] {
                const auto *row = occurrence();
                if (!row || reader->document()->frameAt(row->cursor.position()) != row->owner) return false;
                const auto raw = row->caption.text();
                if (row->cursor.position() - row->caption.position() != raw.size() - 1
                    || raw != caption + " " + QChar(QChar::ObjectReplacementCharacter)) return false;
                const auto start = row->caption.position();
                for (qsizetype i = 0; i < caption.size(); ++i) {
                    QTextCursor letter(reader->document());
                    letter.setPosition(start + int(i));
                    letter.setPosition(start + int(i) + 1, QTextCursor::KeepAnchor);
                    if (letter.charFormat().fontItalic() != (i >= caption.size() - italicText.size())) return false;
                }
                return true;
            };
            // The retained Entry contains one table. Bind the native grid by caption owner,
            // document order, and every authored cell span. The endpoint text occurs in two rows.
            struct GridCensus {
                bool complete = false;
                QList<QTextTable *> matches;
            };
            const auto matchingGrids = [&] {
                GridCensus census;
                const auto *row = occurrence();
                if (!row) return census;
                QList<QTextFrame *> pending{row->owner.data()};
                int seen = 0;
                while (!pending.isEmpty() && seen++ < 128) {
                    auto *frame = pending.takeLast();
                    pending.append(frame->childFrames());
                    auto *grid = qobject_cast<QTextTable *>(frame);
                    if (!grid || grid == row->owner.data() || grid->firstPosition() <= row->caption.position()
                        || grid->rows() != rows.size() || grid->columns() != gridColumns) continue;
                    bool exact = true;
                    for (int r = 0; r < grid->rows(); ++r) {
                        int column = 0;
                        for (const auto &value : rows.at(r).toObject().value("cells").toArray()) {
                            const auto actual = grid->cellAt(r, column);
                            const int width = value.toObject().value("colspan").toInt();
                            exact = exact && actual.isValid() && actual.row() == r && actual.column() == column
                                && actual.columnSpan() == width && actual.rowSpan() == 1;
                            column += width;
                        }
                    }
                    if (exact) census.matches.append(grid);
                }
                census.complete = pending.isEmpty();
                return census;
            };
            const auto viewportHit = [&] {
                auto *control = button();
                return control && control->isVisible()
                    && reader->viewport()->rect().contains(borderInViewport(control, reader->viewport()).center().toPoint());
            };
            const auto hasState = [&](bool expanded) {
                auto *control = button();
                const auto *row = occurrence();
                const auto &label = expanded ? shutLabel : openLabel;
                if (!control || !row || row->pendingToggle || !control->isEnabled()
                    || control->isChecked() != expanded || row->expanded != expanded || control->text() != label
                    || control->accessibleName() != label || window.readingUncommitted_
                    || window.currentEntry_ != expectedEntry || !captionStyle()) return false;
                const auto grids = matchingGrids();
                if (!grids.complete) return false;
                if (expanded) return grids.matches.size() == 1;
                return grids.matches.isEmpty()
                    && reader->document()->find("pisanych", 0, QTextDocument::FindWholeWords).isNull();
            };
            const auto snapshot = [&] {
                auto *doc = reader->document();
                const auto *row = occurrence();
                auto *control = button();
                const auto grids = matchingGrids();
                const auto raw = doc->toRawText();
                QJsonObject data{{"loading", window.loading_}, {"uncommitted", window.readingUncommitted_},
                    {"status", window.resultStatus_->text().left(4096)}, {"visible_reader", reader->isVisible()},
                    {"document_units", raw.size()}, {"document_raw_utf8_sha256", sha(raw.toUtf8())},
                    {"revision", doc->revision()}, {"composition", qint64(window.readingComposition_)},
                    {"host_current", window.readingDisclosures_ && window.readingDisclosures_->current()},
                    {"host_rows", window.readingDisclosures_ ? window.readingDisclosures_->occurrences.size() : 0},
                    {"bound_owner", bool(row)}, {"grid_census_complete", grids.complete},
                    {"matching_grids", grids.matches.size()},
                    {"viewport", rectangle(QRectF(reader->viewport()->rect()))},
                    {"hscroll", reader->horizontalScrollBar()->value()}, {"hmax", reader->horizontalScrollBar()->maximum()},
                    {"vscroll", reader->verticalScrollBar()->value()}, {"vmax", reader->verticalScrollBar()->maximum()}};
                if (auto *host = window.readingDisclosures_.data(); host && host->current()) {
                    QJsonArray candidates;
                    for (const auto &candidate : host->occurrences) {
                        if (candidates.size() == 8) break;
                        QJsonObject record{{"path", candidate.path.left(256)},
                            {"source_sha256", sha(QJsonDocument(candidate.block).toJson(QJsonDocument::Compact))},
                            {"has_caption", candidate.caption.isValid()},
                            {"atom_position", candidate.cursor.position()}};
                        if (candidate.caption.isValid())
                            record.insert("caption", candidate.caption.text().left(256));
                        if (candidate.owner)
                            record.insert("owner_bounds", QJsonArray{candidate.owner->firstPosition(), candidate.owner->lastPosition()});
                        candidates.append(record);
                    }
                    data.insert("host_candidates_prefix", candidates);
                }
                if (row) {
                    data.insert("path", row->path);
                    data.insert("caption_raw", row->caption.text().left(256));
                    data.insert("caption_position", row->caption.position());
                    data.insert("atom_position", row->cursor.position());
                    data.insert("caption_style_equal", captionStyle());
                    data.insert("owner_bounds", QJsonArray{row->owner->firstPosition(), row->owner->lastPosition()});
                    data.insert("expanded", row->expanded);
                    data.insert("pending", row->pendingToggle);
                }
                if (control) {
                    data.insert("control_text", control->text());
                    data.insert("enabled", control->isEnabled());
                    data.insert("checked", control->isChecked());
                    data.insert("focused", control->hasFocus());
                    data.insert("border", rectangle(borderInViewport(control, reader->viewport())));
                }
                return data;
            };
            auto opened = snapshot();
            opened.insert("settled", loaded);
            opened.insert("kind", window.api_ ? window.api_->kind() : QString());
            opened.insert("language", window.api_ ? window.api_->language() : QString());
            opened.insert("root", window.api_ ? window.api_->root() : QString());
            checkpoint(prefix + "-opened", opened);
            check(loaded && !report.contains("product_refusal") && !window.readingUncommitted_
                  && reader->isVisible() && window.api_ && window.api_->root() == library
                  && window.api_->language() == "Pol" && window.api_->kind() == "language"
                  && window.currentResponse_.object() == expectedResponse && window.currentEntry_ == expectedEntry,
                  "ordinary UI selected same library and committed exactly the complete retained Entry");
            check(hasState(false) && !window.disclosureStates_.contains(path),
                  "fresh owner and italic caption start collapsed with Tèmprakin");
            if (reopen) break;

            const auto makeReachable = [&] {
                const auto *row = occurrence();
                if (!row) return false;
                reader->verticalScrollBar()->setValue(qRound(window.readingDisclosures_->rectangle(*row).top()) - 40);
                return settle(viewportHit);
            };
            const bool initialHit = makeReachable();
            checkpoint("before-mouse", snapshot());
            check(initialHit && hasState(false), "initial caption control visible at its native border");
            const auto beforeMouse = window.readingComposition_;
            auto *control = button();
            QTest::mouseClick(control, Qt::LeftButton, Qt::NoModifier,
                              borderInViewport(control, control).center().toPoint());
            const bool expanded = settle([&] { return window.readingComposition_ > beforeMouse && hasState(true); });
            checkpoint("after-mouse", snapshot());
            check(expanded, "native mouse expansion committed and rebound the exact Gulung owner");

            auto *grid = matchingGrids().matches.first();
            const auto last = grid->cellAt(finalRow, finalCol);
            auto end = last.firstCursorPosition();
            const int firstPosition = end.position();
            const int lastPosition = last.lastCursorPosition().position();
            end.setPosition(lastPosition, QTextCursor::KeepAnchor);
            bool plain = true;
            for (int pos = firstPosition; pos < lastPosition; ++pos) {
                QTextCursor character(reader->document());
                character.setPosition(pos);
                character.setPosition(pos + 1, QTextCursor::KeepAnchor);
                plain &= !character.charFormat().isAnchor() && character.charFormat().anchorHref().isEmpty();
            }
            const auto spanMate = grid->cellAt(finalRow, finalCol + 1);
            auto endpoint = snapshot();
            endpoint.insert("cell", QJsonObject{{"row", last.row()}, {"column", last.column()},
                {"rowspan", last.rowSpan()}, {"colspan", last.columnSpan()},
                {"start", firstPosition}, {"end", lastPosition}, {"text", end.selectedText().left(256)},
                {"same_spanned_cell", spanMate.firstCursorPosition().position() == firstPosition},
                {"plain", plain}, {"grid_start", grid->firstPosition()}, {"grid_end", grid->lastPosition()}});
            checkpoint("endpoint", endpoint);
            check(last.isValid() && last.row() == finalRow && last.column() == finalCol && last.columnSpan() == 2
                  && spanMate.firstCursorPosition().position() == firstPosition && grid == end.currentTable()
                  && firstPosition < lastPosition && plain && end.selectedText() == "pisanych",
                  "exact native last cell range and plain text across the authored span");
            end.setPosition(firstPosition);
            const QPointer<QTextDocument> doc(reader->document());
            const QPointer<QAbstractTextDocumentLayout> layout(doc->documentLayout());
            const int revision = doc->revision();
            const auto composition = window.readingComposition_;
            reader->setTextCursor(end);
            reader->ensureCursorVisible();
            const auto stable = [&] {
                return doc && layout && reader->document() == doc && doc->documentLayout() == layout
                    && doc->revision() == revision && window.readingComposition_ == composition;
            };
            const bool visible = settle([&] {
                return !stable() || reader->viewport()->rect().intersects(reader->cursorRect(end));
            });
            auto reach = snapshot();
            if (stable()) reach.insert("caret", rectangle(QRectF(reader->cursorRect(end))));
            checkpoint("endpoint-visible", reach);
            check(visible && stable() && hasState(true) && reader->textCursor().position() == firstPosition
                  && reader->viewport()->rect().intersects(reader->cursorRect(end)), "exact final-cell caret reached in current viewport");

            const bool hit = makeReachable();
            if (hit && button()) button()->setFocus(Qt::TabFocusReason);
            const bool focus = settle([&] { return button() && button()->hasFocus() && viewportHit(); });
            checkpoint("before-keyboard", snapshot());
            check(hit && focus && hasState(true), "native keyboard focus on exact expanded owner");
            const auto beforeKey = window.readingComposition_;
            QTest::keyClick(button(), Qt::Key_Space);
            const bool collapsed = settle([&] {
                return window.readingComposition_ > beforeKey && hasState(false) && button()->hasFocus() && viewportHit();
            });
            checkpoint("after-keyboard", snapshot());
            check(collapsed, "Space collapsed the current owner, hid the grid and restored focus");
            window.close();
        }
        report.insert("bew_pisany", QJsonObject{{"status", "PASS"}, {"fresh_opens", 2},
            {"mouse_expand", true}, {"keyboard_collapse", true}, {"native_grid_columns", gridColumns},
            {"authored_rows", rows.size()}, {"authored_cells", authored}});
    }
