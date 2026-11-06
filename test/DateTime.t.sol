// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DateTime} from "../src/libs/DateTime.sol";

contract DateTimeTest is Test {
    function _ts(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        return DateTime.timestampFromDate(y, m, d);
    }

    function test_epoch() public pure {
        assertEq(_ts(1970, 1, 1), 0);
        assertEq(_ts(2025, 1, 15), 1736899200);
    }

    function test_addMonths_clampsDay() public pure {
        assertEq(DateTime.addMonths(_ts(2025, 1, 31), 1), _ts(2025, 2, 28));
        assertEq(DateTime.addMonths(_ts(2024, 1, 31), 1), _ts(2024, 2, 29)); // leap year
        assertEq(DateTime.addMonths(_ts(2025, 3, 31), 1), _ts(2025, 4, 30));
        assertEq(DateTime.addMonths(_ts(2025, 1, 31), 2), _ts(2025, 3, 31));
    }

    function test_addMonths_yearRollAndTimeOfDay() public pure {
        assertEq(DateTime.addMonths(_ts(2025, 11, 20) + 3600, 3), _ts(2026, 2, 20) + 3600);
        assertEq(DateTime.addMonths(_ts(2025, 6, 10), 12), _ts(2026, 6, 10));
        assertEq(DateTime.addMonths(_ts(2025, 6, 10), 120), _ts(2035, 6, 10));
        assertEq(DateTime.addMonths(_ts(2025, 6, 10), 0), _ts(2025, 6, 10));
    }

    function test_diffMonths() public pure {
        assertEq(DateTime.diffMonths(_ts(2025, 1, 15), _ts(2025, 1, 15)), 0);
        assertEq(DateTime.diffMonths(_ts(2025, 1, 15), _ts(2025, 2, 14)), 0);
        assertEq(DateTime.diffMonths(_ts(2025, 1, 15), _ts(2025, 2, 15)), 1);
        assertEq(DateTime.diffMonths(_ts(2025, 1, 31), _ts(2025, 2, 28)), 1); // clamped boundary
        assertEq(DateTime.diffMonths(_ts(2025, 1, 31), _ts(2025, 2, 27)), 0);
        assertEq(DateTime.diffMonths(_ts(2025, 1, 15), _ts(2026, 1, 15)), 12);
        assertEq(DateTime.diffMonths(_ts(2025, 5, 1), _ts(2025, 1, 1)), 0); // to < from
    }

    function test_startOfMonth() public pure {
        assertEq(DateTime.startOfMonth(_ts(2025, 1, 15) + 12 hours), _ts(2025, 1, 1));
        assertEq(DateTime.startOfMonth(_ts(2024, 2, 29) + 86399), _ts(2024, 2, 1));
    }

    function test_daysInMonth() public pure {
        assertEq(DateTime.daysInMonth(2024, 2), 29);
        assertEq(DateTime.daysInMonth(2025, 2), 28);
        assertEq(DateTime.daysInMonth(2100, 2), 28); // century, not leap
        assertEq(DateTime.daysInMonth(2000, 2), 29);
        assertEq(DateTime.daysInMonth(2025, 4), 30);
        assertEq(DateTime.daysInMonth(2025, 12), 31);
    }

    function testFuzz_civilRoundTrip(uint32 daysSinceEpoch) public pure {
        (uint256 y, uint256 m, uint256 d) = DateTime.daysToDate(daysSinceEpoch);
        assertEq(DateTime.daysFromDate(y, m, d), daysSinceEpoch);
        assertTrue(m >= 1 && m <= 12 && d >= 1 && d <= DateTime.daysInMonth(y, m));
    }

    function testFuzz_addThenDiff(uint32 ts, uint8 months) public pure {
        uint256 from = bound(ts, 1_000_000_000, 4_000_000_000);
        uint256 to = DateTime.addMonths(from, months);
        assertEq(DateTime.diffMonths(from, to), months);
        assertTrue(to >= from);
    }
}
