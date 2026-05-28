//
//  PhoneDialPadScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 25/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 PhoneDialPadScreen presents UI/UX for entering phone number for making calls.
 It shows a grid of digits with call and delete digits button.
 */
struct PhoneDialPadScreen<ViewModel: PhoneDialPadViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @ObservedObject private var viewModel: ViewModel
    
    @State private var isAppearing = false
    @State private var deleteButtonIcon = "delete-number-icon-light"
    
    private let columns = [
        GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
    ]
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        GeometryReader { geo in
            let hPad: CGFloat = 54
            let bottomReserve: CGFloat = 96  // PhoneScreen bottom padding clearance
            let fixedVertical: CGFloat = 40 + 60 + 40 + 16 + 74  // topPad + numberDisplay + gridTopPad + dialPad topPad + dialButton
            let availableWidth = geo.size.width - hPad * 2
            let availableGridHeight = geo.size.height - bottomReserve - fixedVertical
            let buttonDiameter = min(74, floor(availableWidth / 3))
            let rowSpacing = min(20, max(8, floor((availableGridHeight - buttonDiameter * 4) / 3)))

            VStack(alignment: .center, spacing: 0) {

                // Typed number
                GlacierLabel(
                    text: viewModel.phoneNumber.isEmpty ? " " : viewModel.phoneNumber,
                    font: .neueHassGroteskFont(ofSize: 35)
                )
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(
                        action: {
                            guard let pastedString = UIPasteboard.general.string else { return }
                            let filtered = pastedString.filter { "0123456789+*#".contains($0) }
                            viewModel.formatNumber(with: "(XXX) XXX-XXXX", number: filtered)
                        },
                        label: {
                            GlacierLabel(
                                text: NSLocalizedString("Paste", comment: "Paste button title"),
                                font: .bodyRegular
                            )
                        }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 40)

                // Alpha-numeric digits
                LazyVGrid(columns: columns, spacing: rowSpacing) {
                    PhoneDialPadButton(title: "1", subTitle: nil, diameter: buttonDiameter, action: { viewModel.appendDigit("1") })
                    PhoneDialPadButton(title: "2", subTitle: "ABC", diameter: buttonDiameter, action: { viewModel.appendDigit("2") })
                    PhoneDialPadButton(title: "3", subTitle: "DEF", diameter: buttonDiameter, action: { viewModel.appendDigit("3") })

                    PhoneDialPadButton(title: "4", subTitle: "GHI", diameter: buttonDiameter, action: { viewModel.appendDigit("4") })
                    PhoneDialPadButton(title: "5", subTitle: "JKL", diameter: buttonDiameter, action: { viewModel.appendDigit("5") })
                    PhoneDialPadButton(title: "6", subTitle: "MNO", diameter: buttonDiameter, action: { viewModel.appendDigit("6") })

                    PhoneDialPadButton(title: "7", subTitle: "PQRS", diameter: buttonDiameter, action: { viewModel.appendDigit("7") })
                    PhoneDialPadButton(title: "8", subTitle: "TUV", diameter: buttonDiameter, action: { viewModel.appendDigit("8") })
                    PhoneDialPadButton(title: "9", subTitle: "WXYZ", diameter: buttonDiameter, action: { viewModel.appendDigit("9") })

                    PhoneDialPadButton(icon: "star-icon", diameter: buttonDiameter, action: { viewModel.appendDigit("*") })
                    PhoneDialPadButton(title: "0", subTitle: "+", diameter: buttonDiameter, action: {
                        viewModel.appendDigit("0")
                    }, longPressAction: {
                        viewModel.addPlusSign()
                    })
                    PhoneDialPadButton(title: "#", diameter: buttonDiameter, action: { viewModel.appendDigit("#") })
                }
                .padding(.horizontal, hPad)
                .padding(.top, 40)

                ZStack {
                    // Dial button
                    Button(
                        action: {
                            viewModel.startCall()
                        },
                        label: {
                            ZStack {
                                Circle()
                                    .fill(Color.greenHighlight)
                                    .frame(width: buttonDiameter, height: buttonDiameter)

                                Image("dial-icon")
                                    .resizable()
                                    .frame(width: 32, height: 32)
                            }
                        }
                    )

                    HStack(alignment: .center) {
                        Spacer()

                        // Delete Button
                        if !viewModel.phoneNumber.isEmpty {
                            Button(
                                action: {
                                    viewModel.deleteDigit()
                                },
                                label: {
                                    Image(deleteButtonIcon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 33, height: 25)
                                        .frame(width: buttonDiameter, height: buttonDiameter)
                                        .contentShape(Rectangle())
                                        .simultaneousGesture(
                                            DragGesture(minimumDistance: 0)
                                                .onChanged { _ in
                                                    viewModel.startAutoDeleteOfDigits()
                                                }
                                                .onEnded { _ in
                                                    viewModel.stopAutoDeleteOfDigits()
                                                }
                                        )
                                        .transition(.scale.combined(with: .opacity))
                                        .onDisappear {
                                            viewModel.stopAutoDeleteOfDigits()
                                        }
                                }
                            )
                            .frame(width: buttonDiameter, height: buttonDiameter)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, 62)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            isAppearing = true
            setupColors(for: glacierColorScheme.activeScheme)
        }
        .onDisappear {
            isAppearing = false
        }
        .onChange(of: glacierColorScheme.activeScheme) { newScheme in
            guard isAppearing else { return }
            setupColors(for: newScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        deleteButtonIcon = scheme == .dark ? "delete-number-icon-dark" : "delete-number-icon-light"
    }
}
