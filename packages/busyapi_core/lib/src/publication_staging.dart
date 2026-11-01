// Names are not access capabilities. Writers still allocate exclusive private
// directories and retain their existing fd, identity and no-overwrite checks.
// A leading dot is not needed for privacy (0700 supplies that), and Snap's
// standard home interface excludes hidden children directly under the home.
const fileStagingPrefix = 'busyapi-export-';
const outputStagingPrefix = 'busyapi-output-';
const fileArchivePrefix = 'busyapi-file-move-';

// Retained version-1 publication/recovery receipts can name the original
// hidden directories. Recognizing a name never authorizes a write or replay.
bool isFileArchiveDirectoryName(String name) =>
    name.startsWith(fileArchivePrefix) ||
    name.startsWith('.$fileArchivePrefix');

bool isOutputStagingDirectoryName(String name) =>
    name.startsWith(outputStagingPrefix) ||
    name.startsWith('.$outputStagingPrefix');
