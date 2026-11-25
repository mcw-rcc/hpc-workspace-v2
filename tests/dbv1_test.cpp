#define CATCH_CONFIG_MAIN // This tells Catch to provide a main() - only do this in one cpp file
#include <catch2/catch_test_macros.hpp>

#include "../src/caps.h"
#include "../src/dbv1.h"

Cap caps{};

bool debugflag = false;
bool traceflag = false;
int debuglevel = 0;

TEST_CASE("Database v1 yaml parser", "[dbv1]") {

    DBEntryV1 entry(nullptr);

    entry.readFromString(std::string{
        R"yaml(
workspace: /a/path
expiration: 1734701876
extensions: 3
reminder: 0
mailaddress: ""
comment: ""
)yaml"});

    SECTION("readentry") {
        REQUIRE(entry.getWSPath() == "/a/path");
        REQUIRE(entry.getExpiration() == 1734701876);
        REQUIRE(entry.getExtension() == 3);
        REQUIRE(entry.getMailaddress() == "");
    }
}

// MCW: time of last extension is kept in the DB entry as "extended"
TEST_CASE("Database v1 yaml parser: extended field", "[dbv1][mcw]") {
    SECTION("missing in upstream entries -> 0") {
        DBEntryV1 entry(nullptr);
        entry.readFromString(std::string{R"yaml(
workspace: /a/path
creation: 1734000000
expiration: 1734701876
extensions: 1
)yaml"});
        REQUIRE(entry.getLastExtension() == 0);
        REQUIRE(entry.getCreation() == 1734000000);
    }
    SECTION("present") {
        DBEntryV1 entry(nullptr);
        entry.readFromString(std::string{R"yaml(
workspace: /a/path
creation: 1734000000
expiration: 1734701876
extended: 1734500000
extensions: 0
)yaml"});
        REQUIRE(entry.getLastExtension() == 1734500000);
    }
}
