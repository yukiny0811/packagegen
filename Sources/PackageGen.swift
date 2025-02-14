// Copyright 2025 Yuki Kuwashima

import ArgumentParser
import Foundation

/**
 A command-line tool that generates a Swift package from a predefined template.

 The tool performs the following steps:

 1. Checks whether a directory with the specified package name already exists in the current directory.
 2. Creates a temporary directory.
 3. Downloads a template ZIP file from GitHub.
 4. Unzips the downloaded template.
 5. Locates the extracted template folder.
 6. Moves the template folder to the desired package directory.
 7. Replaces all occurrences of the placeholder string within file contents and names with the provided package name.

 - Note: The tool terminates with an error if a directory with the specified package name already exists.
 */
@main
struct PackageGen: ParsableCommand {

    /// The name of the package to be generated.
    @Argument(help: "The name of the package")
    var packageName: String

    /**
     The main entry point of the command.

     This method performs the following operations in sequence:

     - Verifies that no directory with the given package name exists in the current working directory.
     - Creates a temporary directory.
     - Downloads the template ZIP file from GitHub using the `curl` command.
     - Unzips the downloaded ZIP file using the system's unzip utility.
     - Searches for the extracted template folder.
     - Moves the extracted folder to a new directory named after the package.
     - Replaces all occurrences of the placeholder string "PACKAGE_TEMPLATE_NAME" with the specified package name in all files and directory names.

     - Throws: An error if any file or process operation fails.
     */
    mutating func run() throws {
        let fileManager = FileManager.default

        // Check for an existing directory with the package name in the current directory.
        let currentDirURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let newPackageDir = currentDirURL.appendingPathComponent(packageName)
        if fileManager.fileExists(atPath: newPackageDir.path) {
            fatalError("Error: Directory \(packageName) already exists.")
        }

        // Create a temporary directory.
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("PackageGen_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        print("Temporary directory created at \(tempDir.path)")

        // Download the template ZIP from GitHub.
        let templateZipURL = URL(string: "https://github.com/yukiny0811/SwiftPackageTemplate/archive/refs/heads/main.zip")!
        let zipFileURL = tempDir.appendingPathComponent("template.zip")
        try downloadZipUsingCurl(from: templateZipURL.absoluteString, to: zipFileURL)

        // Unzip the downloaded template using the system's unzip utility.
        print("Unzipping template...")
        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        unzipProcess.arguments = ["unzip", "-q", zipFileURL.path, "-d", tempDir.path]
        try unzipProcess.run()
        unzipProcess.waitUntilExit()
        print("Unzip completed.")

        // Locate the extracted template folder.
        let contents = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        guard let extractedDir = contents.first(where: { url in
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            // Exclude the ZIP file itself.
            return isDir.boolValue && url.lastPathComponent != "template.zip"
        }) else {
            fatalError("Error: Could not locate the extracted template folder.")
        }
        print("Extracted template folder found: \(extractedDir.lastPathComponent)")

        // Move the extracted template folder to the target directory.
        try fileManager.moveItem(at: extractedDir, to: newPackageDir)
        print("Moved extracted template to \(newPackageDir.path)")

        // Replace all occurrences of the placeholder in file contents and names.
        print("Replacing placeholder text in files...")
        try replacePlaceholder(in: newPackageDir, placeholder: "PACKAGE_TEMPLATE_NAME", with: packageName)
        print("Placeholder replacement completed.")

        print("DONE! Package \(packageName) generated at \(newPackageDir.path)")
    }

    // MARK: - Placeholder Replacement

    /**
     Replaces all occurrences of a specified placeholder string within file contents and file/directory names.

     The function performs the following steps:

     1. Iterates over all files within the specified directory and replaces occurrences of the placeholder string in their contents.
     2. Renames files and directories whose names contain the placeholder string. If a conflict occurs, directories are merged if possible.

     - Parameters:
       - directory: The URL of the directory to process.
       - placeholder: The placeholder string to search for.
       - newValue: The string to replace the placeholder with.

     - Throws: An error if any file operations or string processing fails.
     */
    func replacePlaceholder(in directory: URL, placeholder: String, with newValue: String) throws {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey]

        // Step 1: Replace placeholder in the contents of files.
        let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])!
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            if resourceValues.isDirectory == true { continue }

            do {
                var content = try String(contentsOf: fileURL, encoding: .utf8)
                if content.contains(placeholder) {
                    content = content.replacingOccurrences(of: placeholder, with: newValue)
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                    print("Updated content in \(fileURL.path)")
                }
            } catch {
                print("Warning: Skipping file \(fileURL.path) due to error: \(error.localizedDescription)")
            }
        }

        // Step 2: Replace placeholder in file and directory names.
        let allItems = try fileManager.subpathsOfDirectory(atPath: directory.path)
        // Sort items by path depth in descending order.
        let sortedItems = allItems.sorted {
            $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count
        }

        for relativePath in sortedItems {
            if relativePath.contains(placeholder) {
                let oldURL = directory.appendingPathComponent(relativePath)
                let newRelativePath = relativePath.replacingOccurrences(of: placeholder, with: newValue)
                let newURL = directory.appendingPathComponent(newRelativePath)

                // Create the parent directory for the new path if it does not exist.
                let newURLParent = newURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: newURLParent, withIntermediateDirectories: true, attributes: nil)

                if fileManager.fileExists(atPath: newURL.path) {
                    // If both items are directories, merge them.
                    var isDirOld: ObjCBool = false
                    var isDirNew: ObjCBool = false
                    fileManager.fileExists(atPath: oldURL.path, isDirectory: &isDirOld)
                    fileManager.fileExists(atPath: newURL.path, isDirectory: &isDirNew)

                    if isDirOld.boolValue && isDirNew.boolValue {
                        try mergeDirectories(source: oldURL, destination: newURL)
                        print("Merged directory \(oldURL.path) into \(newURL.path)")
                    } else {
                        print("Warning: Destination \(newURL.path) already exists. Skipping rename for \(oldURL.path).")
                    }
                } else {
                    try fileManager.moveItem(at: oldURL, to: newURL)
                    print("Renamed \(oldURL.path) to \(newURL.path)")
                }
            }
        }
    }

    // MARK: - Directory Merging

    /**
     Merges the contents of two directories.

     The function moves all items from the source directory to the destination directory.
     In the event of a conflict where both the source and destination contain directories with the same name,
     the merge is performed recursively. After successfully moving the contents, the source directory is removed.

     - Parameters:
       - source: The URL of the source directory.
       - destination: The URL of the destination directory.

     - Throws: An error if any file operations fail.
     */
    func mergeDirectories(source: URL, destination: URL) throws {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
        for item in items {
            let destItem = destination.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: destItem.path) {
                // If both items are directories, merge them recursively.
                var isDirSource: ObjCBool = false
                var isDirDest: ObjCBool = false
                fileManager.fileExists(atPath: item.path, isDirectory: &isDirSource)
                fileManager.fileExists(atPath: destItem.path, isDirectory: &isDirDest)
                if isDirSource.boolValue && isDirDest.boolValue {
                    try mergeDirectories(source: item, destination: destItem)
                } else {
                    // Skip conflicting items if they are not both directories.
                    print("Warning: Skipping merging \(item.path) because \(destItem.path) exists.")
                }
            } else {
                try fileManager.moveItem(at: item, to: destItem)
                print("Moved \(item.path) to \(destItem.path)")
            }
        }
        try fileManager.removeItem(at: source)
    }

    // MARK: - ZIP Download

    /**
     Downloads a ZIP file from a specified URL using the `curl` command.

     The function uses the system's `curl` command to download the ZIP file from the provided URL
     and saves it to the specified destination.

     - Parameters:
       - urlString: The URL string from which to download the ZIP file.
       - destination: The file URL where the downloaded ZIP should be saved.

     - Throws: An error if the `curl` command fails or if the process terminates with a non-zero exit code.
     */
    func downloadZipUsingCurl(from urlString: String, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // -L follows redirects; -o specifies the output file.
        process.arguments = ["curl", "-o", destination.path, "-L", urlString]

        print("Executing curl to download ZIP from \(urlString)")
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            fatalError("Error: Curl download failed with exit code \(process.terminationStatus)")
        }
        print("ZIP successfully downloaded to \(destination.path)")
    }
}
