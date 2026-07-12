import Foundation

enum ConstantsHealthKit {
    
    /// if the time between the last and last but one reading is less than minimiumTimeBetweenTwoReadingsInMinutes, then no new event event will be stored in healthkit - except if there's been a disconnect in between these two readings
    static let minimiumTimeBetweenTwoReadingsInMinutes = 4.75

    /// when the continuous carbs import runs for the first time (ie no query anchor persisted yet), only samples younger than this number of days are imported
    static let carbsImportMaxAgeInDays = 30.0

    /// when importing a carb sample from healthkit, if a carbs treatment already exists within this window (in seconds) around the sample timestamp with (almost) the same amount, the sample is considered a duplicate and not imported
    static let carbsImportDedupeWindowInSeconds = 150.0

}
