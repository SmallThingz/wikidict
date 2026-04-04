import { render } from "solid-js/web";
import { Route, Router } from "@solidjs/router";

import App, { EntryPage, HomePage, HistoryPage, BookmarksPage } from "./App";
import "./styles.css";

render(
  () => (
    <Router root={App}>
      <Route path="/" component={HomePage} />
      <Route path="/entry/:term" component={EntryPage} />
      <Route path="/history" component={HistoryPage} />
      <Route path="/bookmarks" component={BookmarksPage} />
    </Router>
  ),
  document.getElementById("root")!,
);
