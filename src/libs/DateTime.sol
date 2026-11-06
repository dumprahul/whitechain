// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice Calendar arithmetic (UTC) for budgets, schedules and vesting.
/// @dev Civil-date conversion follows the well-known days-from-civil algorithm.
///      Adding months clamps the day to the target month's length (Jan 31 + 1 month = Feb 28/29).
library DateTime {
    uint256 internal constant SECONDS_PER_DAY = 86400;
    int256 internal constant OFFSET19700101 = 2440588;

    function isLeapYear(uint256 year) internal pure returns (bool) {
        return (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0);
    }

    function daysInMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        if (month == 1 || month == 3 || month == 5 || month == 7 || month == 8 || month == 10 || month == 12) {
            return 31;
        }
        if (month != 2) return 30;
        return isLeapYear(year) ? 29 : 28;
    }

    function daysFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        int256 _year = int256(year);
        int256 _month = int256(month);
        int256 _day = int256(day);
        int256 m = (_month - 14) / 12;
        int256 d = _day - 32075 + (1461 * (_year + 4800 + m)) / 4 + (367 * (_month - 2 - m * 12)) / 12
            - (3 * ((_year + 4900 + m) / 100)) / 4 - OFFSET19700101;
        return uint256(d);
    }

    function daysToDate(uint256 _days) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 L = int256(_days) + 68569 + OFFSET19700101;
        int256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        int256 _year = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * _year) / 4 + 31;
        int256 _month = (80 * L) / 2447;
        int256 _day = L - (2447 * _month) / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;
        year = uint256(_year);
        month = uint256(_month);
        day = uint256(_day);
    }

    function timestampFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        return daysFromDate(year, month, day) * SECONDS_PER_DAY;
    }

    /// @notice Timestamp of the first second of the month containing `ts`.
    function startOfMonth(uint256 ts) internal pure returns (uint256) {
        (uint256 y, uint256 m,) = daysToDate(ts / SECONDS_PER_DAY);
        return timestampFromDate(y, m, 1);
    }

    /// @notice `ts` plus `months` calendar months, day clamped to the month length, time of day kept.
    function addMonths(uint256 ts, uint256 months) internal pure returns (uint256) {
        (uint256 y, uint256 m, uint256 d) = daysToDate(ts / SECONDS_PER_DAY);
        uint256 total = y * 12 + (m - 1) + months;
        y = total / 12;
        m = (total % 12) + 1;
        uint256 dim = daysInMonth(y, m);
        if (d > dim) d = dim;
        return timestampFromDate(y, m, d) + (ts % SECONDS_PER_DAY);
    }

    /// @notice Largest n such that addMonths(from, n) <= to (0 when to <= from).
    function diffMonths(uint256 from, uint256 to) internal pure returns (uint256 n) {
        if (to <= from) return 0;
        (uint256 y1, uint256 m1,) = daysToDate(from / SECONDS_PER_DAY);
        (uint256 y2, uint256 m2,) = daysToDate(to / SECONDS_PER_DAY);
        n = (y2 * 12 + m2) - (y1 * 12 + m1);
        if (n > 0 && addMonths(from, n) > to) n--;
    }
}
