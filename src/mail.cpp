#include "mail.h"
#include "spdlog/spdlog.h"

#include <unistd.h>

extern bool debugflag;

namespace mail {

// Internal callback for curl
static size_t readEmailCallback(void* ptr, size_t size, size_t nmemb, void* userp) {
    EmailData* emailData = static_cast<EmailData*>(userp);

    size_t available = emailData->content.length() - emailData->index;
    if (available == 0) {
        return 0;
    }

    size_t to_copy = std::min(available, size * nmemb);
    memcpy(ptr, emailData->content.c_str() + emailData->index, to_copy);
    emailData->index += to_copy;

    return to_copy;
}

void initCurl() { curl_global_init(CURL_GLOBAL_DEFAULT); }

void cleanupCurl() { curl_global_cleanup(); }

bool sendCurl(const std::string& smtpUrl, const std::string& mail_from, std::vector<std::string>& mail_to,
              const std::string& completeMail) {
    CURL* curl;
    CURLcode res = CURLE_OK;

    curl = curl_easy_init();
    if (!curl) {
        if (debugflag)
            spdlog::debug("Failed to initialize curl");
        return false;
    }

    EmailData emailData(completeMail);

    curl_easy_setopt(curl, CURLOPT_URL, smtpUrl.c_str());

    struct curl_slist* recipients = nullptr;
    for (const auto& mailaddress : mail_to) {
        recipients = curl_slist_append(recipients, mailaddress.c_str());
    }
    curl_easy_setopt(curl, CURLOPT_MAIL_RCPT, recipients);
    curl_easy_setopt(curl, CURLOPT_MAIL_FROM, mail_from.c_str());

    curl_easy_setopt(curl, CURLOPT_READFUNCTION, readEmailCallback);
    curl_easy_setopt(curl, CURLOPT_READDATA, &emailData);
    curl_easy_setopt(curl, CURLOPT_UPLOAD, 1L);

    if (debugflag) {
        curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
    }

    res = curl_easy_perform(curl);

    if (debugflag) {
        if (res == CURLE_OK) {
            spdlog::debug("Email sent successfully");
        } else {
            spdlog::debug("curl_easy_perform() failed: {}", curl_easy_strerror(res));
        }
    }

    curl_slist_free_all(recipients);
    curl_easy_cleanup(curl);

    return (res == CURLE_OK);
}

std::string generateMailDateFormat(const time_t time) {
    // generous buffer: far-future years and localized names must not make strftime run out of space
    char timeString[128];
    struct tm tm_buf = {};
    // both calls can fail (EOVERFLOW for extreme timestamps / result does not fit); never read the
    // buffer then, and never invent a date, as callers print this in subject and body of mails
    if (localtime_r(&time, &tm_buf) == nullptr ||
        std::strftime(timeString, sizeof(timeString), "%a, %d %h %Y %X %z", &tm_buf) == 0) {
        spdlog::warn("could not format timestamp {} as mail date", time);
        return "(date out of range)";
    }
    return std::string(timeString);
}

std::string generateMessageID(const std::string& domain) {
    auto now = std::time(nullptr);
    auto pid = getpid();

    std::hash<std::string> hasher;
    std::string unique_string = std::to_string(now) + std::to_string(pid) + std::to_string(rand());
    auto hash = hasher(unique_string);

    return fmt::format("{}.{}.{}@{}", now, pid, hash, domain);
}

std::string generateToHeader(std::vector<std::string> mail_to) {
    std::string to_header;
    for (size_t i = 0; i < mail_to.size(); ++i) {
        if (i > 0)
            to_header += ", ";
        to_header += mail_to[i];
    }
    return to_header;
}

} // namespace mail

namespace mail {

// MCW: parse the nightly "user address" map; bad lines are skipped
UserMailMap parseUserMailMap(const std::string& content) {
    UserMailMap map;
    size_t pos = 0;
    while (pos <= content.size()) {
        size_t end = content.find('\n', pos);
        if (end == std::string::npos)
            end = content.size();
        std::string line = content.substr(pos, end - pos);
        pos = end + 1;
        auto hash = line.find('#');
        if (hash != std::string::npos)
            line.erase(hash);
        const char* ws = " \t\r";
        auto b = line.find_first_not_of(ws);
        if (b == std::string::npos)
            continue;
        auto e = line.find_first_of(ws, b);
        if (e == std::string::npos)
            continue;
        auto b2 = line.find_first_not_of(ws, e);
        if (b2 == std::string::npos)
            continue;
        auto e2 = line.find_first_of(ws, b2);
        std::string user = line.substr(b, e - b);
        std::string addr = line.substr(b2, e2 == std::string::npos ? std::string::npos : e2 - b2);
        // plain addr-spec only: one '@', text on both sides, no header/list characters
        auto at = addr.find('@');
        if (at == std::string::npos || at == 0 || at + 1 >= addr.size() ||
            addr.find('@', at + 1) != std::string::npos || addr.find_first_of("<>,;:\"()[]\\") != std::string::npos)
            continue;
        map[user] = addr;
    }
    return map;
}

// MCW: see mail.h
std::string resolveRecipient(const std::string& stored, const std::string& owner, const UserMailMap& map) {
    if (stored.find('@') != std::string::npos)
        return stored;
    if (auto it = map.find(owner); !owner.empty() && it != map.end())
        return it->second;
    if (auto it = map.find(stored); !stored.empty() && it != map.end())
        return it->second;
    return stored;
}

} // namespace mail
