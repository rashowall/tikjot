import SwiftUI
import TikjotDomain
import TikjotHolidays

/// Public-holiday country menu (Settings and onboarding): every country we have a holiday file for,
/// named and sorted in the app language, plus "None".
struct HolidayCountryPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("", selection: Binding(get: { model.settings.holidayCountry }, set: { v in model.updateSettings { $0.holidayCountry = v } })) {
            ForEach(HolidayEngine.countries(sortedFor: model.language), id: \.self) { c in
                Text(HolidayEngine.countryName(c, language: model.language)).tag(c)
            }
            Divider()
            Text(String(localized: "None")).tag("NONE")
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}
