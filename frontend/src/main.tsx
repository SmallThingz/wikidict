import { render } from "solid-js/web";
import { Route, Router } from "@solidjs/router";

import App, { EntryPage, HomePage } from "./App";
import "./styles.css";

render(
  () => (
    <Router root={App}>
      <Route path="/" component={HomePage} />
      <Route path="/entry/:term" component={EntryPage} />
    </Router>
  ),
  document.getElementById("root")!,
);
