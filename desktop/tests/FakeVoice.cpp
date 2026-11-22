// Lightweight process fixture for MediaPanel's real QProcess voice contract.
// No Qt linkage: the fixture must not spend the voice-query deadline loading UI plugins.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <thread>

namespace {
std::string environment(const char *name) {
    const char *value = std::getenv(name);
    return value ? value : "";
}
}
int main(int argc, char **argv) {
    const std::string root = environment("WIKIDICT_MEDIA_TEST_ROOT");
    if (root.empty() || environment("XDG_CACHE_HOME") != root + "/cache" ||
        environment("XDG_CONFIG_HOME") != root + "/config" ||
        environment("XDG_DATA_HOME") != root + "/data") return 2;
    if (argc == 2 && std::string(argv[1]) == "--voices") {
        std::fputs("Pty Language Age/Gender VoiceName File Other Languages\n 2 en-gb M English gmw/en\n 5 fr-fr M French roa/fr\n", stdout);
        return 0;
    }
    if ((argc == 4 || (argc == 5 && std::string(argv[4]) == "-m")) &&
        std::string(argv[1]) == "-v" && std::string(argv[3]) == "--stdin") {
        const std::string words((std::istreambuf_iterator<char>(std::cin)), {});
        if (std::cin.bad()) return 2;
        std::ofstream output(environment("WIKIDICT_TEST_SPEECH_CAPTURE"), std::ios::binary | std::ios::trunc);
        if (!output) return 2;
        output << argv[2] << '\n' << words;
        output.close();
        if (!output) return 2;
        if (words.starts_with("hold")) std::this_thread::sleep_for(std::chrono::seconds(1));
        return 0;
    }
    return 2;
}
