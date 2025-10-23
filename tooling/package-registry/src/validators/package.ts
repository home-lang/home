import semver from 'semver';

export interface PackageMetadata {
    name: string;
    version: string;
    description?: string;
    author?: string;
    license?: string;
    homepage?: string;
    repository?: string;
    keywords?: string[];
    dependencies?: Record<string, string>;
}

export interface ValidationResult {
    valid: boolean;
    errors: string[];
}

export function validatePackage(metadata: PackageMetadata): ValidationResult {
    const errors: string[] = [];

    // Validate name
    if (!metadata.name) {
        errors.push('Package name is required');
    } else if (!/^[a-z0-9-_]+$/.test(metadata.name)) {
        errors.push('Package name must contain only lowercase letters, numbers, hyphens, and underscores');
    } else if (metadata.name.length < 2 || metadata.name.length > 50) {
        errors.push('Package name must be between 2 and 50 characters');
    }

    // Validate version
    if (!metadata.version) {
        errors.push('Version is required');
    } else if (!semver.valid(metadata.version)) {
        errors.push('Invalid semantic version');
    }

    // Validate description
    if (metadata.description && metadata.description.length > 500) {
        errors.push('Description must not exceed 500 characters');
    }

    // Validate keywords
    if (metadata.keywords) {
        if (!Array.isArray(metadata.keywords)) {
            errors.push('Keywords must be an array');
        } else if (metadata.keywords.length > 10) {
            errors.push('Maximum 10 keywords allowed');
        } else {
            for (const keyword of metadata.keywords) {
                if (typeof keyword !== 'string' || keyword.length > 30) {
                    errors.push('Each keyword must be a string of max 30 characters');
                    break;
                }
            }
        }
    }

    // Validate dependencies
    if (metadata.dependencies) {
        if (typeof metadata.dependencies !== 'object') {
            errors.push('Dependencies must be an object');
        } else {
            for (const [dep, version] of Object.entries(metadata.dependencies)) {
                if (!semver.validRange(version)) {
                    errors.push(`Invalid version range for dependency "${dep}": ${version}`);
                }
            }
        }
    }

    return {
        valid: errors.length === 0,
        errors
    };
}
