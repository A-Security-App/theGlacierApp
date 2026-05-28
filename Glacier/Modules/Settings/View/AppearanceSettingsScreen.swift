//
//  AppearanceSettingsScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 03/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 AppearanceSettingsScreen presents available color scheme options (system, light and dark) so that user acn set preffered app color scheme.
 */
struct AppearanceSettingsScreen<ViewModel: AppearanceSettingsViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @SwiftUI.Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    
    @StateObject private var viewModel: ViewModel
    
    @State private var descriptionTextColor: Color?
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        NavigationStack {
            ZStack {
                GlacierBackground()
                    .ignoresSafeArea()
                
                VStack(alignment: .center, spacing: 16) {
                    ForEach(viewModel.schemes, id: \.self) { scheme in
                        GlacierViewContainer {
                            VStack(alignment: .leading, spacing: 40) {
                                HStack(alignment: .center, spacing: 8) {
                                    GlacierLabel(
                                        text: scheme.title,
                                        font: .bodyThick
                                    )
                                    
                                    Spacer()
                                    
                                    GlacierImage(
                                        name: .constant(viewModel.selectedScheme.title == scheme.title ? "radioButton-selected-icon" : "radioButton-deselected-icon"),
                                        width: 16,
                                        height: 16,
                                        shouldAdaptToColorSchemeChange: true
                                    )
                                    .frame(width: 16, height: 16)
                                }
                                
                                GlacierLabel(
                                    text: scheme.description,
                                    font: .bodyRegular,
                                    customTextColor: $descriptionTextColor
                                )
                                .padding(.trailing, 60)
                            }
                        }
                        .onTapGesture {
                            viewModel.selectedScheme = scheme
                        }
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 28)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GlacierLabel(
                        text: NSLocalizedString("Appearance", comment: "Appearance settings screen title"),
                        font: .headerTwo
                    )
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        GlacierImage(
                            name: .constant("cross-icon"),
                            contentMode: .fit,
                            width: 24,
                            height: 24,
                            shouldAdaptToColorSchemeChange: true
                        )
                    }
                }
            }
        }
        .onFirstAppear {
            viewModel.glacierColorScheme = glacierColorScheme
        }
        .presentationDetents([.fraction(0.75)])
        .onAppear {
            descriptionTextColor = glacierColorScheme.activeScheme == .light ? .grey60 : .grey40
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            descriptionTextColor = colorScheme == .light ? .grey60 : .grey40
        }
    }
}
