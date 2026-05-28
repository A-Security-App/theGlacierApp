//
//  GlacierSearchBar.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 14/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierSearchBar provides UI/UX for text search functionality.
 It's binding `searchText` property updates host components about the real time search text change event.
 */
struct GlacierSearchBar: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    @FocusState private var isTextFieldFocused: Bool
    
    @Binding private var searchText: String
    @Binding private var isFocused: Bool
    
    @State private var isAppearing = false
    @State private var backgroundColor: Color = .white
    @State private var tintColor: Color? = .grey40
    
    private var placeholder: String
    private var width: CGFloat
    private var height: CGFloat
    private var cornerRadius: CGFloat
    private var keyboardType: UIKeyboardType
    private var onSubmit: (() -> Void)?
    private var onTextCleared: (() -> Void)?
    private var onSearchTapped: (() -> Void)?

    // MARK: - Initializer

    init(
        searchText: Binding<String>,
        placeholder: String,
        width: CGFloat = CGFloat.infinity,
        height: CGFloat = 50,
        cornerRadius: CGFloat = 25,
        keyboardType: UIKeyboardType = .default,
        isFocused: Binding<Bool> = .constant(false),
        onSubmit: (() -> Void)? = nil,
        onTextCleared: (() -> Void)? = nil,
        onSearchTapped: (() -> Void)? = nil
    ) {
        self._searchText = searchText
        self._isFocused = isFocused

        self.placeholder = placeholder
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.keyboardType = keyboardType
        self.onSubmit = onSubmit
        self.onTextCleared = onTextCleared
        self.onSearchTapped = onSearchTapped
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(backgroundColor)
                .frame(maxWidth: width, maxHeight: height)
                .onTapGesture {
                    isTextFieldFocused = true
                }

            HStack(alignment: .center, spacing: 8) {
                Button(
                    action: {
                        if !searchText.isEmpty {
                            onSearchTapped?()
                        }
                    },
                    label: {
                        GlacierImage(
                            name: .constant("search-icon"),
                            width: 16,
                            height: 16,
                            shouldAdaptToColorSchemeChange: false,
                            customTintColor: $tintColor
                        )
                    }
                )

                TextField(placeholder, text: $searchText)
                    .multilineTextAlignment(.leading)
                    .font(.bodyThick)
                    .foregroundColor(tintColor)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(keyboardType)
                    .focused($isTextFieldFocused)
                    .frame(maxHeight: height)
                    .onSubmit {
                        isTextFieldFocused = false
                        onSubmit?()
                    }
                
                Spacer()
                
                if !searchText.isEmpty {
                    Button(
                        action: {
                            searchText = ""
                            isTextFieldFocused = true
                            onTextCleared?()
                        },
                        label: {
                            ZStack(alignment: .center) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(backgroundColor)
                                    .frame(width: height - 10, height: height - 10)
                                
                                GlacierImage(
                                    name: .constant("cross-icon"),
                                    width: 20,
                                    height: 20,
                                    shouldAdaptToColorSchemeChange: false,
                                    customTintColor: $tintColor
                                )
                            }
                        }
                    )
                }
            }
            .padding(.vertical, 24)
            .padding(.leading, 24)
            .padding(.trailing, 10)
        }
        .frame(maxHeight: height)
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
        .onChange(of: isFocused) { focused in
            isTextFieldFocused = focused
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        backgroundColor = scheme == .dark ? .grey70 : .grey30
        tintColor = scheme == .dark ? .grey40 : .grey60
    }
}
