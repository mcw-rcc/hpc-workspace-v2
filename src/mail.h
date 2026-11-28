#ifndef MAIL_H
#define MAIL_H

#include <ctime>
#include <curl/curl.h>
#include <map>
#include <string>
#include <vector>

#include "fmt/base.h"

namespace mail {

// Mail helper struct
struct EmailData {
    std::string content;
    size_t index;

    EmailData(const std::string& content) : content(content), index(0) {}
};

// Initialize Curl
void initCurl();

// Cleanup Curl
void cleanupCurl();

// Send a Mail with curl to the smtpUrl
bool sendCurl(const std::string& smtpUrl, const std::string& mail_from, std::vector<std::string>& mail_to,
              const std::string& completeMail);

// Generate the Date Format used for Mime Mails from time_t
std::string generateMailDateFormat(const time_t time);

// Generate a message ID from current time, PID, and Random component
// Domain parameter is required - no default
std::string generateMessageID(const std::string& domain);

// Generate the To Header for Mails
std::string generateToHeader(std::vector<std::string> mail_to);

// MCW: user -> mail address map, one "user address" pair per line ('#' comments).
// Written nightly from the LDAP mail attribute (hpc-workspace-tools ws_labs.py).
using UserMailMap = std::map<std::string, std::string>;
UserMailMap parseUserMailMap(const std::string& content);

// MCW: address to mail a workspace owner at. An address the user gave (-m or
// ~/.ws_user.conf, it contains '@') is kept. Otherwise ws_allocate stored the bare
// username, so the owner (or that username) is looked up in the map. Returns the
// stored value unchanged when there is no map entry, or the owner's username when
// nothing was stored.
std::string resolveRecipient(const std::string& stored, const std::string& owner, const UserMailMap& map);

} // namespace mail

#endif
